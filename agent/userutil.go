package main

import (
	"fmt"
	"os"
	"os/user"
	"strconv"
)

// lookupUser returns the username for the given uid, or "" on failure.
// Uses os/user which works with CGO_ENABLED=0 via /etc/passwd parsing.
func lookupUser(uid int) string {
	u, err := user.LookupId(strconv.Itoa(uid))
	if err != nil {
		return ""
	}
	return u.Username
}

// lookupGroup returns the group name for the given gid, or "" on failure.
func lookupGroup(gid int) string {
	g, err := user.LookupGroupId(strconv.Itoa(gid))
	if err != nil {
		return ""
	}
	return g.Name
}

// formatMode returns the octal permission string like "0644" or "0755".
func formatMode(m os.FileMode) string {
	return fmt.Sprintf("%04o", m.Perm())
}
