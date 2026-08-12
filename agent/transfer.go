package main

import (
	"compress/gzip"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/zeebo/blake3"
)

// hashBlake3Stream computes blake3 of r in streaming fashion.
// Returns hex hash and bytes read.
func hashBlake3Stream(r io.Reader) (string, int64, error) {
	h := blake3.New()
	buf := make([]byte, 64*1024)
	var total int64
	for {
		n, err := r.Read(buf)
		if n > 0 {
			if _, werr := h.Write(buf[:n]); werr != nil {
				return "", 0, werr
			}
			total += int64(n)
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			return "", 0, err
		}
	}
	return hex.EncodeToString(h.Sum(nil)), total, nil
}

// --- send mode (--send): server -> Mac, file -> stdout ---

type sendFlags struct {
	Path     string
	Offset   int64
	Compress string
}

func parseSendArgs(args []string) (*sendFlags, error) {
	f := &sendFlags{}
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--path":
			if i+1 >= len(args) {
				return nil, fmt.Errorf("--path requires a value")
			}
			f.Path = args[i+1]
			i++
		case "--offset":
			if i+1 >= len(args) {
				return nil, fmt.Errorf("--offset requires a value")
			}
			n, err := strconv.ParseInt(args[i+1], 10, 64)
			if err != nil {
				return nil, fmt.Errorf("invalid --offset: %v", err)
			}
			f.Offset = n
			i++
		case "--compress":
			if i+1 >= len(args) {
				return nil, fmt.Errorf("--compress requires a value")
			}
			f.Compress = args[i+1]
			i++
		default:
			return nil, fmt.Errorf("unknown arg: %s", args[i])
		}
	}
	if f.Path == "" {
		return nil, fmt.Errorf("--path is required")
	}
	if f.Compress != "" && f.Compress != "gzip" {
		return nil, fmt.Errorf("unsupported --compress: %s", f.Compress)
	}
	return f, nil
}

func runSend(args []string) {
	f, err := parseSendArgs(args)
	if err != nil {
		writeErr(CodeEPROTO, err.Error())
		os.Exit(2)
	}
	abs, e := absPath(f.Path)
	if e != nil {
		writeErr(e.Code, e.Message)
		os.Exit(1)
	}
	file, err := os.Open(abs)
	if err != nil {
		writeErr(osErrToAgentCode(err), err.Error())
		os.Exit(1)
	}
	defer file.Close()

	info, err := file.Stat()
	if err != nil {
		writeErr(osErrToAgentCode(err), err.Error())
		os.Exit(1)
	}
	if info.IsDir() {
		writeErr(CodeEISDIR, "is a directory")
		os.Exit(1)
	}

	total := info.Size() - f.Offset
	if f.Offset > 0 {
		if _, err := file.Seek(f.Offset, io.SeekStart); err != nil {
			writeErr(CodeEINTERNAL, "seek: "+err.Error())
			os.Exit(1)
		}
	}

	start := time.Now()
	var sink io.Writer = os.Stdout
	if f.Compress == "gzip" {
		gw := gzip.NewWriter(os.Stdout)
		defer gw.Close()
		sink = gw
	}
	pw := newProgressWriter(sink, total)
	buf := make([]byte, 64*1024)
	written, err := io.CopyBuffer(pw, file, buf)
	if err != nil {
		writeErr(osErrToAgentCode(err), err.Error())
		os.Exit(1)
	}
	// Flush gzip before computing hash of the raw file bytes sent.
	if gw, ok := sink.(*gzip.Writer); ok {
		if err := gw.Close(); err != nil {
			writeErr(CodeEINTERNAL, "gzip flush: "+err.Error())
			os.Exit(1)
		}
	}
	// Hash the range we sent: reopen and hash from offset.
	h, _, _ := hashRange(abs, f.Offset, written)
	writeDone(written, h, time.Since(start).Milliseconds())
}

// hashRange computes blake3 over [offset, offset+size) of the file at path.
func hashRange(path string, offset, size int64) (string, int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", 0, err
	}
	defer f.Close()
	if offset > 0 {
		if _, err := f.Seek(offset, io.SeekStart); err != nil {
			return "", 0, err
		}
	}
	h := blake3.New()
	buf := make([]byte, 64*1024)
	var remaining int64 = size
	var total int64
	for remaining > 0 {
		toRead := int64(len(buf))
		if remaining < toRead {
			toRead = remaining
		}
		n, err := f.Read(buf[:toRead])
		if n > 0 {
			h.Write(buf[:n])
			total += int64(n)
			remaining -= int64(n)
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			return "", 0, err
		}
	}
	return hex.EncodeToString(h.Sum(nil)), total, nil
}

// --- recv mode (--recv): Mac -> server, stdin -> file ---

type recvFlags struct {
	Path          string
	Offset        int64
	Compress      string
	ExpectSize    int64
	ExpectSizeSet bool
	ExpectHash    string
}

func parseRecvArgs(args []string) (*recvFlags, error) {
	f := &recvFlags{}
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--path":
			if i+1 >= len(args) {
				return nil, fmt.Errorf("--path requires a value")
			}
			f.Path = args[i+1]
			i++
		case "--offset":
			if i+1 >= len(args) {
				return nil, fmt.Errorf("--offset requires a value")
			}
			n, err := strconv.ParseInt(args[i+1], 10, 64)
			if err != nil {
				return nil, fmt.Errorf("invalid --offset: %v", err)
			}
			f.Offset = n
			i++
		case "--compress":
			if i+1 >= len(args) {
				return nil, fmt.Errorf("--compress requires a value")
			}
			f.Compress = args[i+1]
			i++
		case "--expect-size":
			if i+1 >= len(args) {
				return nil, fmt.Errorf("--expect-size requires a value")
			}
			n, err := strconv.ParseInt(args[i+1], 10, 64)
			if err != nil {
				return nil, fmt.Errorf("invalid --expect-size: %v", err)
			}
			f.ExpectSize = n
			f.ExpectSizeSet = true
			i++
		case "--expect-hash":
			if i+1 >= len(args) {
				return nil, fmt.Errorf("--expect-hash requires a value")
			}
			f.ExpectHash = strings.ToLower(args[i+1])
			i++
		default:
			return nil, fmt.Errorf("unknown arg: %s", args[i])
		}
	}
	if f.Path == "" {
		return nil, fmt.Errorf("--path is required")
	}
	if !f.ExpectSizeSet {
		return nil, fmt.Errorf("--expect-size is required")
	}
	if f.Compress != "" && f.Compress != "gzip" {
		return nil, fmt.Errorf("unsupported --compress: %s", f.Compress)
	}
	return f, nil
}

func runRecv(args []string) {
	f, err := parseRecvArgs(args)
	if err != nil {
		writeErr(CodeEPROTO, err.Error())
		os.Exit(2)
	}
	abs, e := absPath(f.Path)
	if e != nil {
		writeErr(e.Code, e.Message)
		os.Exit(1)
	}
	partPath := abs + ".dropship-part"

	// Determine write mode: append (resume) or truncate.
	flag := os.O_CREATE | os.O_WRONLY
	if f.Offset > 0 {
		flag |= os.O_APPEND
	} else {
		flag |= os.O_TRUNC
	}
	partFile, err := os.OpenFile(partPath, flag, 0644)
	if err != nil {
		writeErr(osErrToAgentCode(err), err.Error())
		os.Exit(1)
	}
	defer partFile.Close()

	var src io.Reader = os.Stdin
	if f.Compress == "gzip" {
		gr, err := gzip.NewReader(os.Stdin)
		if err != nil {
			writeErr(CodeEPROTO, "gzip: "+err.Error())
			os.Exit(1)
		}
		defer gr.Close()
		src = gr
	}

	start := time.Now()
	pw := newProgressWriter(partFile, f.ExpectSize)
	buf := make([]byte, 64*1024)
	written, err := io.CopyBuffer(pw, src, buf)
	if err != nil {
		writeErr(osErrToAgentCode(err), err.Error())
		os.Exit(1)
	}
	if err := partFile.Sync(); err != nil {
		writeErr(CodeEINTERNAL, "sync: "+err.Error())
		os.Exit(1)
	}
	if err := partFile.Close(); err != nil {
		writeErr(CodeEINTERNAL, "close: "+err.Error())
		os.Exit(1)
	}

	// Size check: actual bytes (offset + received) must equal expect-size.
	// This catches truncated transfers (e.g. SSH disconnect causing premature EOF).
	actual := f.Offset + written
	if actual != f.ExpectSize {
		// Keep .part for potential resume.
		writeErr(CodeESIZE, fmt.Sprintf("size mismatch: expected %d got %d", f.ExpectSize, actual))
		os.Exit(1)
	}

	// Hash check (if provided).
	if f.ExpectHash != "" {
		h, _, herr := hashRange(partPath, 0, actual)
		if herr != nil {
			writeErr(CodeEINTERNAL, "hash: "+herr.Error())
			os.Exit(1)
		}
		if h != f.ExpectHash {
			// Keep .part for potential resume.
			writeErr(CodeEHASH, "hash mismatch: expected "+f.ExpectHash+" got "+h)
			os.Exit(1)
		}
	}
	// Atomic rename.
	if err := os.Rename(partPath, abs); err != nil {
		writeErr(CodeEINTERNAL, "rename: "+err.Error())
		os.Exit(1)
	}
	// Final hash of the committed file for the done report.
	finalHash, _, _ := hashRange(abs, 0, actual)
	writeDone(actual, finalHash, time.Since(start).Milliseconds())
}

// osErrToAgentCode maps an OS error to a stable code string.
func osErrToAgentCode(err error) string {
	if err == nil {
		return CodeEINTERNAL
	}
	if pe, ok := err.(*os.PathError); ok {
		err = pe.Err
	}
	if errno, ok := err.(syscall.Errno); ok {
		switch errno {
		case syscall.ENOENT:
			return CodeENOENT
		case syscall.EACCES, syscall.EPERM:
			return CodeEACCES
		case syscall.EEXIST:
			return CodeEEXIST
		case syscall.ENOSPC:
			return CodeENOSPC
		case syscall.EISDIR:
			return CodeEISDIR
		case syscall.ENOTDIR:
			return CodeENOTDIR
		}
	}
	if os.IsNotExist(err) {
		return CodeENOENT
	}
	if os.IsPermission(err) {
		return CodeEACCES
	}
	return CodeEINTERNAL
}
