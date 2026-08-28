import {test} from "node:test"
import assert from "node:assert/strict"

import {attachmentDownloadUrls} from "../../assets/js/veejr/hooks/shared.js"

test("federated attachments are relayed through a same-origin browser URL", () => {
  const urls = attachmentDownloadUrls({
    id: "encrypted-video-id",
    origin: "https://remote.example",
  })

  assert.equal(
    urls[0],
    "/blobs/encrypted-video-id?origin=https%3A%2F%2Fremote.example",
  )
  assert.equal(urls.some((url) => url.startsWith("https://remote.example")), false)
})

test("legacy local attachments retain both same-origin download routes", () => {
  assert.deepEqual(attachmentDownloadUrls({id: "local-blob"}), [
    "/api/blobs/local-blob",
    "/blobs/local-blob",
  ])
})
