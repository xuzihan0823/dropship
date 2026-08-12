package main

import (
	"strings"
	"testing"
)

func TestParseRecvArgsAcceptsZeroExpectedSize(t *testing.T) {
	flags, err := parseRecvArgs([]string{
		"--path", "/tmp/empty.txt",
		"--expect-size", "0",
		"--offset", "0",
	})
	if err != nil {
		t.Fatalf("parseRecvArgs rejected a zero-byte file: %v", err)
	}
	if !flags.ExpectSizeSet || flags.ExpectSize != 0 {
		t.Fatalf("expected an explicitly provided zero size, got %+v", flags)
	}
}

func TestParseRecvArgsRejectsMissingExpectedSize(t *testing.T) {
	_, err := parseRecvArgs([]string{"--path", "/tmp/file.txt"})
	if err == nil || !strings.Contains(err.Error(), "--expect-size is required") {
		t.Fatalf("expected missing --expect-size error, got %v", err)
	}
}
