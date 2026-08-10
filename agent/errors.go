package main

// Stable error codes per PROTOCOL.md §4.
const (
	CodeENOENT   = "ENOENT"
	CodeEACCES   = "EACCES"
	CodeEEXIST   = "EEXIST"
	CodeENOSPC   = "ENOSPC"
	CodeEISDIR   = "EISDIR"
	CodeENOTDIR  = "ENOTDIR"
	CodeEHASH    = "EHASH"
	CodeESIZE    = "ESIZE"
	CodeEPROTO   = "EPROTO"
	CodeEINTERNAL = "EINTERNAL"
)

// AgentError maps a stable machine code to a human-readable message.
type AgentError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *AgentError) Error() string { return e.Code + ": " + e.Message }

func errf(code, format string, args ...interface{}) *AgentError {
	return &AgentError{Code: code, Message: fmtSprintf(format, args...)}
}
