//go:build !payload

package main

// Without the payload tag, runtime/ is looked up next to the executable.
var payloadZip []byte
