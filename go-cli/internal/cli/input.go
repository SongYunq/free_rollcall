package cli

import (
	"bufio"
	"context"
	"io"
)

type inputLine struct {
	text    string
	scanned bool
	err     error
}

// lineReader uses one worker for an entire session and scans only on request.
// Run can stop waiting even if the underlying Read or Close cannot be interrupted.
type lineReader struct {
	in       io.Reader
	requests chan struct{}
	results  chan inputLine
	done     chan struct{}
}

func newLineReader(in io.Reader) *lineReader {
	reader := &lineReader{
		in: in, requests: make(chan struct{}), results: make(chan inputLine), done: make(chan struct{}),
	}
	go func() {
		scanner := bufio.NewScanner(in)
		scanner.Buffer(make([]byte, 4096), 1024*1024)
		for {
			select {
			case <-reader.done:
				return
			case <-reader.requests:
			}
			scanned := scanner.Scan()
			line := inputLine{text: scanner.Text(), scanned: scanned, err: scanner.Err()}
			select {
			case <-reader.done:
				return
			case reader.results <- line:
			}
			if !scanned {
				return
			}
		}
	}()
	return reader
}

func (reader *lineReader) next(ctx context.Context) (inputLine, error) {
	select {
	case <-ctx.Done():
		return inputLine{}, ctx.Err()
	case reader.requests <- struct{}{}:
	}
	select {
	case <-ctx.Done():
		return inputLine{}, ctx.Err()
	case line := <-reader.results:
		return line, nil
	}
}

func (reader *lineReader) stop(cancelled bool) {
	close(reader.done)
	if cancelled {
		if input, ok := reader.in.(io.Closer); ok {
			// Real terminal Close is not guaranteed to interrupt Read, and a custom
			// Close may itself block. Neither may delay cancellation of the command.
			go func() { _ = input.Close() }()
		}
	}
}
