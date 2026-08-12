package main

import (
	"fmt"
	"os"
	"os/signal"
	"syscall"
)

const version = "1.0.1"

func main() {
	// SIGPIPE: when stdout pipe breaks (e.g. client closes), exit quietly
	// keeping any .part file for resume.
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGPIPE)
	go func() {
		s := <-sigCh
		// Reset default behavior and re-raise, so exit code reflects the signal.
		signal.Stop(sigCh)
		_ = syscall.Kill(syscall.Getpid(), s.(syscall.Signal))
		os.Exit(1)
	}()

	args := os.Args[1:]

	// Simple flag dispatch. We don't use the `flag` package because
	// --send/--recv/--stdio are mutually exclusive modes, not boolean flags.
	if len(args) == 0 {
		usage()
		os.Exit(2)
	}

	switch args[0] {
	case "--version":
		fmt.Printf("dropship-agent %s\n", version)
		os.Exit(0)
	case "--stdio":
		runStdio()
	case "--recv":
		runRecv(args[1:])
	case "--send":
		runSend(args[1:])
	case "-h", "--help":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "unknown mode: %s\n", args[0])
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, `usage:
  agent --stdio
  agent --recv --path <path> [--offset N] [--compress gzip] [--expect-size N] [--expect-hash <hex>]
  agent --send --path <path> [--offset N] [--compress gzip]
  agent --version`)
}
