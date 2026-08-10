package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"syscall"
	"time"
)

// Entry is the directory/file record shared by list/stat ops.
// Field names are fixed by PROTOCOL.md §2.1.
type Entry struct {
	Name          string `json:"name"`
	Path          string `json:"path"`
	IsDir         bool   `json:"isDir"`
	IsSymlink     bool   `json:"isSymlink"`
	SymlinkTarget string `json:"symlinkTarget"`
	Size          int64  `json:"size"`
	Mode          string `json:"mode"`
	ModTime       int64  `json:"modTime"`
	Owner         string `json:"owner"`
	Group         string `json:"group"`
}

// respJob carries a response back to the stdout writer goroutine.
type respJob struct {
	id   string
	data interface{}
	err  *AgentError
}

type request struct {
	ID   string          `json:"id"`
	Op   string          `json:"op"`
	Args json.RawMessage `json:"args"`
}

type successResp struct {
	ID   string      `json:"id"`
	OK   bool        `json:"ok"`
	Data interface{} `json:"data"`
}

type errorResp struct {
	ID    string      `json:"id"`
	OK    bool        `json:"ok"`
	Error *AgentError `json:"error"`
}

// runStdio implements the --stdio control mode. It reads NDJSON requests
// line-by-line, dispatches each to a goroutine, and serializes responses
// via a single writer goroutine so concurrent replies never interleave.
func runStdio() {
	dec := json.NewDecoder(os.Stdin)
	enc := json.NewEncoder(os.Stdout)

	respCh := make(chan respJob, 64)
	doneCh := make(chan struct{})

	// Single writer: guarantees one-line-at-a-time on stdout.
	go func() {
		for r := range respCh {
			if r.err != nil {
				_ = enc.Encode(errorResp{ID: r.id, OK: false, Error: r.err})
			} else {
				_ = enc.Encode(successResp{ID: r.id, OK: true, Data: r.data})
			}
		}
		close(doneCh)
	}()

	var wg sync.WaitGroup
	for {
		var req request
		if err := dec.Decode(&req); err != nil {
			if err == io.EOF {
				break
			}
			respCh <- respJob{id: "", err: errf(CodeEPROTO, "decode: %v", err)}
			break
		}
		wg.Add(1)
		go func(r request) {
			defer wg.Done()
			data, err := dispatch(r)
			respCh <- respJob{id: r.ID, data: data, err: err}
		}(req)
	}
	// Wait for all handlers to finish before closing the channel,
	// so no goroutine ever sends on a closed channel.
	wg.Wait()
	close(respCh)
	<-doneCh
}

// dispatch routes a request to its op handler.
func dispatch(req request) (interface{}, *AgentError) {
	switch req.Op {
	case "hello":
		return opHello()
	case "list":
		return opList(req.Args)
	case "stat":
		return opStat(req.Args)
	case "mkdir":
		return opMkdir(req.Args)
	case "remove":
		return opRemove(req.Args)
	case "move":
		return opMove(req.Args)
	case "chmod":
		return opChmod(req.Args)
	case "hash":
		return opHash(req.Args)
	case "space":
		return opSpace(req.Args)
	case "realpath":
		return opRealpath(req.Args)
	default:
		return nil, errf(CodeEPROTO, "unknown op: %s", req.Op)
	}
}

// --- op implementations ---

func opHello() (interface{}, *AgentError) {
	home, _ := os.UserHomeDir()
	return map[string]interface{}{
		"version":  version,
		"protocol": 1,
		"arch":     runtimeGOARCH(),
		"os":       runtimeGOOS(),
		"home":     home,
	}, nil
}

type listArgs struct {
	Path       string `json:"path"`
	ShowHidden bool   `json:"showHidden"`
}

func opList(raw json.RawMessage) (interface{}, *AgentError) {
	var a listArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return nil, errf(CodeEPROTO, "args: %v", err)
	}
	abs, e := absPath(a.Path)
	if e != nil {
		return nil, e
	}
	f, err := os.Open(abs)
	if err != nil {
		return nil, osErrToAgent(err)
	}
	defer f.Close()
	infos, err := f.Readdir(-1)
	if err != nil {
		return nil, osErrToAgent(err)
	}
	entries := make([]Entry, 0, len(infos))
	for _, info := range infos {
		if !a.ShowHidden && len(info.Name()) > 0 && info.Name()[0] == '.' {
			continue
		}
		fp := filepath.Join(abs, info.Name())
		li, err := os.Lstat(fp)
		if err != nil {
			continue
		}
		entries = append(entries, buildEntry(li, fp))
	}
	return map[string]interface{}{"entries": entries}, nil
}

type statArgs struct {
	Path string `json:"path"`
}

func opStat(raw json.RawMessage) (interface{}, *AgentError) {
	var a statArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return nil, errf(CodeEPROTO, "args: %v", err)
	}
	abs, e := absPath(a.Path)
	if e != nil {
		return nil, e
	}
	li, err := os.Lstat(abs)
	if err != nil {
		return nil, osErrToAgent(err)
	}
	return map[string]interface{}{"entry": buildEntry(li, abs)}, nil
}

type mkdirArgs struct {
	Path    string `json:"path"`
	Parents bool   `json:"parents"`
}

func opMkdir(raw json.RawMessage) (interface{}, *AgentError) {
	var a mkdirArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return nil, errf(CodeEPROTO, "args: %v", err)
	}
	abs, e := absPath(a.Path)
	if e != nil {
		return nil, e
	}
	if a.Parents {
		if err := os.MkdirAll(abs, 0755); err != nil {
			return nil, osErrToAgent(err)
		}
	} else {
		if err := os.Mkdir(abs, 0755); err != nil {
			return nil, osErrToAgent(err)
		}
	}
	return map[string]interface{}{}, nil
}

type removeArgs struct {
	Path      string `json:"path"`
	Recursive bool   `json:"recursive"`
}

func opRemove(raw json.RawMessage) (interface{}, *AgentError) {
	var a removeArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return nil, errf(CodeEPROTO, "args: %v", err)
	}
	abs, e := absPath(a.Path)
	if e != nil {
		return nil, e
	}
	if a.Recursive {
		if err := os.RemoveAll(abs); err != nil {
			return nil, osErrToAgent(err)
		}
	} else {
		if err := os.Remove(abs); err != nil {
			return nil, osErrToAgent(err)
		}
	}
	return map[string]interface{}{}, nil
}

type moveArgs struct {
	From string `json:"from"`
	To   string `json:"to"`
}

func opMove(raw json.RawMessage) (interface{}, *AgentError) {
	var a moveArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return nil, errf(CodeEPROTO, "args: %v", err)
	}
	from, e := absPath(a.From)
	if e != nil {
		return nil, e
	}
	to, e := absPath(a.To)
	if e != nil {
		return nil, e
	}
	if err := os.Rename(from, to); err != nil {
		return nil, osErrToAgent(err)
	}
	return map[string]interface{}{}, nil
}

type chmodArgs struct {
	Path string `json:"path"`
	Mode string `json:"mode"`
}

func opChmod(raw json.RawMessage) (interface{}, *AgentError) {
	var a chmodArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return nil, errf(CodeEPROTO, "args: %v", err)
	}
	abs, e := absPath(a.Path)
	if e != nil {
		return nil, e
	}
	mode, err := strconv.ParseUint(a.Mode, 8, 32)
	if err != nil {
		return nil, errf(CodeEPROTO, "invalid mode: %v", err)
	}
	if err := os.Chmod(abs, os.FileMode(mode)); err != nil {
		return nil, osErrToAgent(err)
	}
	return map[string]interface{}{}, nil
}

type hashArgs struct {
	Path  string `json:"path"`
	Algo  string `json:"algo"`
}

func opHash(raw json.RawMessage) (interface{}, *AgentError) {
	var a hashArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return nil, errf(CodeEPROTO, "args: %v", err)
	}
	if a.Algo != "blake3" {
		return nil, errf(CodeEPROTO, "unsupported algo: %s", a.Algo)
	}
	abs, e := absPath(a.Path)
	if e != nil {
		return nil, e
	}
	f, err := os.Open(abs)
	if err != nil {
		return nil, osErrToAgent(err)
	}
	defer f.Close()
	h, size, err := hashBlake3Stream(f)
	if err != nil {
		return nil, errf(CodeEINTERNAL, "hash: %v", err)
	}
	return map[string]interface{}{"hash": h, "size": size}, nil
}

type spaceArgs struct {
	Path string `json:"path"`
}

func opSpace(raw json.RawMessage) (interface{}, *AgentError) {
	var a spaceArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return nil, errf(CodeEPROTO, "args: %v", err)
	}
	abs, e := absPath(a.Path)
	if e != nil {
		return nil, e
	}
	var fs syscall.Statfs_t
	if err := syscall.Statfs(abs, &fs); err != nil {
		return nil, osErrToAgent(err)
	}
	total := int64(fs.Blocks) * int64(fs.Bsize)
	free := int64(fs.Bavail) * int64(fs.Bsize)
	return map[string]interface{}{"totalBytes": total, "freeBytes": free}, nil
}

type realpathArgs struct {
	Path string `json:"path"`
}

func opRealpath(raw json.RawMessage) (interface{}, *AgentError) {
	var a realpathArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return nil, errf(CodeEPROTO, "args: %v", err)
	}
	abs, e := absPath(a.Path)
	if e != nil {
		return nil, e
	}
	return map[string]interface{}{"path": abs}, nil
}

// --- helpers ---

// buildEntry constructs an Entry from a FileInfo for the given path.
// Symlinks are NOT followed: isDir reflects the link itself.
func buildEntry(info os.FileInfo, absPath string) Entry {
	e := Entry{
		Name:    info.Name(),
		Path:    absPath,
		Size:    info.Size(),
		Mode:    formatMode(info.Mode()),
		ModTime: info.ModTime().Unix(),
		IsDir:   info.IsDir(),
	}
	if info.Mode()&os.ModeSymlink != 0 {
		e.IsSymlink = true
		if tgt, err := os.Readlink(absPath); err == nil {
			e.SymlinkTarget = tgt
		}
		e.IsDir = false
	}
	if stat, ok := info.Sys().(*syscall.Stat_t); ok {
		e.Owner = uidToName(stat.Uid)
		e.Group = gidToName(stat.Gid)
	}
	return e
}

func uidToName(uid uint32) string {
	return lookupUser(int(uid))
}

func gidToName(gid uint32) string {
	return lookupGroup(int(gid))
}

// absPath expands ~ and returns an absolute path. Does NOT require the
// path to exist (mkdir operates on non-existing paths).
func absPath(p string) (string, *AgentError) {
	if p == "" {
		return "", errf(CodeEPROTO, "empty path")
	}
	if len(p) >= 1 && p[0] == '~' {
		home, err := os.UserHomeDir()
		if err == nil {
			if p == "~" {
				p = home
			} else if len(p) > 1 && p[1] == '/' {
				p = filepath.Join(home, p[2:])
			}
		}
	}
	abs, err := filepath.Abs(p)
	if err != nil {
		return "", errf(CodeEINTERNAL, "abs: %v", err)
	}
	return abs, nil
}

// osErrToAgent maps common OS errors to stable protocol codes.
func osErrToAgent(err error) *AgentError {
	if err == nil {
		return nil
	}
	if pe, ok := err.(*os.PathError); ok {
		err = pe.Err
	}
	if errno, ok := err.(syscall.Errno); ok {
		switch errno {
		case syscall.ENOENT:
			return &AgentError{Code: CodeENOENT, Message: "no such file or directory"}
		case syscall.EACCES, syscall.EPERM:
			return &AgentError{Code: CodeEACCES, Message: "permission denied"}
		case syscall.EEXIST:
			return &AgentError{Code: CodeEEXIST, Message: "file exists"}
		case syscall.ENOSPC:
			return &AgentError{Code: CodeENOSPC, Message: "no space left on device"}
		case syscall.EISDIR:
			return &AgentError{Code: CodeEISDIR, Message: "is a directory"}
		case syscall.ENOTDIR:
			return &AgentError{Code: CodeENOTDIR, Message: "not a directory"}
		}
	}
	if os.IsNotExist(err) {
		return &AgentError{Code: CodeENOENT, Message: err.Error()}
	}
	if os.IsPermission(err) {
		return &AgentError{Code: CodeEACCES, Message: err.Error()}
	}
	return &AgentError{Code: CodeEINTERNAL, Message: err.Error()}
}

// --- progress reporting on stderr ---

type progressWriter struct {
	w         io.Writer
	total     int64
	written   int64
	lastTick  time.Time
	lastBytes int64
}

func newProgressWriter(w io.Writer, total int64) *progressWriter {
	return &progressWriter{w: w, total: total, lastTick: time.Now()}
}

func (p *progressWriter) Write(buf []byte) (int, error) {
	n, err := p.w.Write(buf)
	if n > 0 {
		p.written += int64(n)
	}
	now := time.Now()
	if now.Sub(p.lastTick) >= 200*time.Millisecond || p.written-p.lastBytes >= 1024*1024 {
		writeProgress(p.written, p.total)
		p.lastTick = now
		p.lastBytes = p.written
	}
	return n, err
}

func writeProgress(bytes, total int64) {
	if total > 0 {
		fmt.Fprintf(os.Stderr, `{"type":"progress","bytes":%d,"total":%d}`+"\n", bytes, total)
	} else {
		fmt.Fprintf(os.Stderr, `{"type":"progress","bytes":%d}`+"\n", bytes)
	}
}

func writeDone(bytes int64, hash string, durationMs int64) {
	fmt.Fprintf(os.Stderr, `{"type":"done","bytes":%d,"hash":"%s","durationMs":%d}`+"\n", bytes, hash, durationMs)
}

func writeErr(code, msg string) {
	fmt.Fprintf(os.Stderr, `{"type":"error","code":"%s","message":"%s"}`+"\n", code, msg)
}
