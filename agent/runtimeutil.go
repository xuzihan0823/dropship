package main

import "runtime"

// runtimeGOARCH returns the current GOARCH. Wrapped so tests can mock.
func runtimeGOARCH() string {
	return runtime.GOARCH
}

// runtimeGOOS returns the current GOOS.
func runtimeGOOS() string {
	return runtime.GOOS
}
