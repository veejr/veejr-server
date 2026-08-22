#!/usr/bin/env python3
"""Encrypt, decrypt, and verify Veejr backup data without exposing passwords."""

from __future__ import annotations

import argparse
import os
import sqlite3
import struct
import tempfile
from pathlib import Path

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.kdf.scrypt import Scrypt


MAGIC = b"VEEJRBAK"
VERSION = 1
SALT_SIZE = 16
NONCE_SIZE = 12
TAG_SIZE = 16
KEY_SIZE = 32
SCRYPT_N = 2**17
SCRYPT_R = 8
SCRYPT_P = 1
CHUNK_SIZE = 1024 * 1024
HEADER = struct.Struct(">8sB16s12s")


def password() -> bytes:
    value = os.environ.get("VEEJR_BACKUP_PASSPHRASE")
    if not value:
        raise SystemExit("VEEJR_BACKUP_PASSPHRASE is not set")
    return value.encode("utf-8")


def derive_key(passphrase: bytes, salt: bytes) -> bytes:
    return Scrypt(
        salt=salt,
        length=KEY_SIZE,
        n=SCRYPT_N,
        r=SCRYPT_R,
        p=SCRYPT_P,
    ).derive(passphrase)


def encrypt(source: Path, destination: Path) -> None:
    salt = os.urandom(SALT_SIZE)
    nonce = os.urandom(NONCE_SIZE)
    header = HEADER.pack(MAGIC, VERSION, salt, nonce)
    encryptor = Cipher(algorithms.AES(derive_key(password(), salt)), modes.GCM(nonce)).encryptor()
    encryptor.authenticate_additional_data(header)

    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(f".{destination.name}.partial")
    try:
        with source.open("rb") as input_file, temporary.open("wb") as output_file:
            output_file.write(header)
            while chunk := input_file.read(CHUNK_SIZE):
                output_file.write(encryptor.update(chunk))
            output_file.write(encryptor.finalize())
            output_file.write(encryptor.tag)
            output_file.flush()
            os.fsync(output_file.fileno())
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def decrypt(source: Path, destination: Path) -> None:
    size = source.stat().st_size
    if size < HEADER.size + TAG_SIZE:
        raise ValueError("backup is too short")

    with source.open("rb") as input_file:
        header = input_file.read(HEADER.size)
        magic, version, salt, nonce = HEADER.unpack(header)
        if magic != MAGIC or version != VERSION:
            raise ValueError("unsupported Veejr backup format")
        input_file.seek(-TAG_SIZE, os.SEEK_END)
        tag = input_file.read(TAG_SIZE)

    decryptor = Cipher(
        algorithms.AES(derive_key(password(), salt)), modes.GCM(nonce, tag)
    ).decryptor()
    decryptor.authenticate_additional_data(header)

    ciphertext_remaining = size - HEADER.size - TAG_SIZE
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(f".{destination.name}.partial")
    try:
        with source.open("rb") as input_file, temporary.open("wb") as output_file:
            input_file.seek(HEADER.size)
            while ciphertext_remaining:
                chunk = input_file.read(min(CHUNK_SIZE, ciphertext_remaining))
                if not chunk:
                    raise ValueError("truncated encrypted backup")
                ciphertext_remaining -= len(chunk)
                output_file.write(decryptor.update(chunk))
            output_file.write(decryptor.finalize())
            output_file.flush()
            os.fsync(output_file.fileno())
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def check_sqlite(database: Path) -> None:
    connection = sqlite3.connect(f"file:{database.as_posix()}?mode=ro", uri=True)
    try:
        result = connection.execute("PRAGMA integrity_check").fetchone()
    finally:
        connection.close()
    if result != ("ok",):
        raise ValueError(f"SQLite integrity check failed for {database.name}: {result!r}")


def self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="veejr-backup-crypto-") as directory:
        root = Path(directory)
        source = root / "source.bin"
        encrypted = root / "encrypted.veejrbak"
        restored = root / "restored.bin"
        content = os.urandom(CHUNK_SIZE + 731)
        source.write_bytes(content)
        encrypt(source, encrypted)
        decrypt(encrypted, restored)
        if restored.read_bytes() != content:
            raise ValueError("encryption round-trip did not reproduce the source")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    for command in ("encrypt", "decrypt"):
        operation = subparsers.add_parser(command)
        operation.add_argument("source", type=Path)
        operation.add_argument("destination", type=Path)

    sqlite_parser = subparsers.add_parser("check-sqlite")
    sqlite_parser.add_argument("database", type=Path)
    subparsers.add_parser("self-test")

    args = parser.parse_args()
    if args.command == "encrypt":
        encrypt(args.source, args.destination)
    elif args.command == "decrypt":
        decrypt(args.source, args.destination)
    elif args.command == "check-sqlite":
        check_sqlite(args.database)
    else:
        self_test()


if __name__ == "__main__":
    main()
