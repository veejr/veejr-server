// LiveView hooks for veejr's client-side crypto.
//
// Security rule: passphrases and secret keys are read from plain DOM inputs
// inside these hooks and never travel over the LiveView socket. Only public
// keys and ciphertext are pushed to the server.
//
// This file is the registry. The hooks themselves live in ./hooks/, grouped so
// that auditing one concern does not mean reading all of them:
//
//   hooks/keys.js            identity key setup, unlock, rewrap, rotate, reset
//   hooks/composer.js        encrypt-and-send
//   hooks/messages.js        rendering decrypted content
//   hooks/self_notes.js      the encrypted notes board and Keep import
//   hooks/notes_document.js  note document, merge, and search logic (no DOM)
//   hooks/contacts_scenes.js the lazily loaded WebGL contact views
//   hooks/craps_table.js     the lazily loaded WebGL craps table
//   hooks/ui.js              hooks with no cryptographic role
//   hooks/shared.js          helpers used by several of the above
//   link_text.js             autolinking URLs found in decrypted text

import {KeySetup, KeyUnlock, KeyRewrap, KeyRotate, KeyReset, KeyLock} from "./hooks/keys.js"
import {Composer} from "./hooks/composer.js"
import {Decrypt, ConversationPreview, MessageBubble} from "./hooks/messages.js"
import {SelfNotes, SelfNotesBoard} from "./hooks/self_notes.js"
import {ContactsOrbit} from "./hooks/contacts_scenes.js"
import {CrapsTable} from "./hooks/craps_table.js"
import {
  ScheduleTime,
  LocalTime,
  MessageConsent,
  InstallApp,
  ChatTheme,
  ContactsTheme,
  ScrollBottom,
  ReplyTo,
  PushSetup,
  AccountStatus,
  AutoDismissFlash,
  PasswordVisibility,
  AvatarUpload,
  GuestConferenceLobby,
} from "./hooks/ui.js"
import VeejrMap from "./map_hook.js"
import {InlineKeyUnlock} from "./key_unlock.js"

// Named exports preserved: this module exported these individually before the
// split, and dropping them would be a silent API change for anything that
// imports one by name.
export {
  KeySetup,
  KeyUnlock,
  KeyRewrap,
  KeyRotate,
  KeyReset,
  KeyLock,
  Composer,
  Decrypt,
  ConversationPreview,
  MessageBubble,
  SelfNotes,
  SelfNotesBoard,
  ContactsOrbit,
  CrapsTable,
  ScheduleTime,
  LocalTime,
  MessageConsent,
  InstallApp,
  ChatTheme,
  ContactsTheme,
  ScrollBottom,
  ReplyTo,
  PushSetup,
  AccountStatus,
  AutoDismissFlash,
  PasswordVisibility,
  AvatarUpload,
  InlineKeyUnlock,
}

export default {
  KeySetup,
  KeyUnlock,
  KeyLock,
  KeyRewrap,
  KeyRotate,
  KeyReset,
  PushSetup,
  AccountStatus,
  InstallApp,
  ChatTheme,
  ContactsTheme,
  ContactsOrbit,
  CrapsTable,
  Composer,
  Decrypt,
  ConversationPreview,
  SelfNotes,
  SelfNotesBoard,
  MessageBubble,
  AutoDismissFlash,
  PasswordVisibility,
  AvatarUpload,
  ReplyTo,
  ScrollBottom,
  GuestConferenceLobby,
  LocalTime,
  MessageConsent,
  ScheduleTime,
  VeejrMap,
  InlineKeyUnlock,
}
