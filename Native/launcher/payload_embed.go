//go:build payload

package main

import _ "embed"

// payload.zip holds runtime/bin/templeos (HolyC runtime plus the drive
// image) and the shared libraries it links against.

//go:embed payload.zip
var payloadZip []byte
