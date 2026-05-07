// hashpw — tiny CLI that prints a bcrypt hash for a plaintext password.
//
// Usage:
//
//	go run ./cmd/hashpw 'mySecret'
//	# or pipe:  echo -n 'mySecret' | go run ./cmd/hashpw
//
// The output is the value to put in ADMIN_PASSWORD_HASH.
package main

import (
	"bufio"
	"fmt"
	"os"

	"golang.org/x/crypto/bcrypt"
)

func main() {
	var pw []byte
	if len(os.Args) >= 2 {
		pw = []byte(os.Args[1])
	} else {
		s, err := bufio.NewReader(os.Stdin).ReadString('\n')
		if err != nil && len(s) == 0 {
			fmt.Fprintln(os.Stderr, "usage: hashpw <password>")
			os.Exit(2)
		}
		// drop trailing newline if present
		if n := len(s); n > 0 && (s[n-1] == '\n' || s[n-1] == '\r') {
			s = s[:n-1]
		}
		pw = []byte(s)
	}
	if len(pw) == 0 {
		fmt.Fprintln(os.Stderr, "empty password")
		os.Exit(2)
	}
	h, err := bcrypt.GenerateFromPassword(pw, 10)
	if err != nil {
		fmt.Fprintln(os.Stderr, "bcrypt:", err)
		os.Exit(1)
	}
	fmt.Println(string(h))
}
