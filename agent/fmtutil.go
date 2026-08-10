package main

import "fmt"

// fmtSprintf is a thin wrapper so errors.go can use variadic formatting
// without importing fmt directly (keeps the error helpers self-contained).
func fmtSprintf(format string, args ...interface{}) string {
	return fmt.Sprintf(format, args...)
}
