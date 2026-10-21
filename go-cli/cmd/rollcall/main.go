package main

import (
	"context"
	"os"
	"os/signal"

	"freerollcall/internal/cli"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	code := cli.Run(ctx, os.Args[1:], os.Stdin, os.Stdout, os.Stderr)
	if ctx.Err() != nil {
		code = 130
	}
	stop()
	os.Exit(code)
}
