package browser

import (
	"context"
	"math/rand"
	"os"
	"time"

	"github.com/chromedp/cdproto/network"
	"github.com/chromedp/chromedp"
)

var userAgents = []string{
	"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
	"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
	"Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
	"Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/121.0",
	"Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:109.0) Gecko/20100101 Firefox/121.0",
}

func getRandomUserAgent() string {
	return userAgents[rand.Intn(len(userAgents))]
}

func getRandomViewport() (int, int) {
	widths := []int{1280, 1366, 1440, 1600, 1920}
	heights := []int{720, 768, 900, 1080}
	w := widths[rand.Intn(len(widths))]
	h := heights[rand.Intn(len(heights))]
	return w, h
}

// Browser wraps CDP via chromedp for headless browser automation.
type Browser struct {
	Timeout time.Duration
}

// New creates a new Browser instance with a default 30s timeout.
func New() *Browser {
	return &Browser{
		Timeout: 30 * time.Second,
	}
}

// Session represents an active browser tab and its underlying process.
type Session struct {
	ctx    context.Context
	cancel context.CancelFunc
}

// NewSession starts a new headless browser session.
// It is the caller's responsibility to call Close() when finished to prevent zombie processes.
func (b *Browser) NewSession(parentCtx context.Context) *Session {
	opts := append(chromedp.DefaultExecAllocatorOptions[:],
		chromedp.Flag("headless", true),
		chromedp.Flag("disable-gpu", true),
		chromedp.Flag("no-sandbox", true),
		chromedp.Flag("disable-blink-features", "AutomationControlled"),
	)

	if proxy := os.Getenv("BROWSER_PROXY"); proxy != "" {
		opts = append(opts, chromedp.ProxyServer(proxy))
	}

	opts = append(opts, chromedp.UserAgent(getRandomUserAgent()))

	w, h := getRandomViewport()
	opts = append(opts, chromedp.WindowSize(w, h))

	allocCtx, allocCancel := chromedp.NewExecAllocator(parentCtx, opts...)
	taskCtx, taskCancel := chromedp.NewContext(allocCtx)

	timeoutCtx, timeoutCancel := context.WithTimeout(taskCtx, b.Timeout)

	combinedCancel := func() {
		timeoutCancel()
		taskCancel()
		allocCancel()
	}

	return &Session{
		ctx:    timeoutCtx,
		cancel: combinedCancel,
	}
}

// Close terminates the browser session and kills the underlying Chrome process.
func (s *Session) Close() {
	s.cancel()
}

// SetCookies sets the provided cookies for the session.
func (s *Session) SetCookies(cookies []*network.CookieParam) error {
	return chromedp.Run(s.ctx, network.SetCookies(cookies))
}

// Navigate opens the specified URL.
func (s *Session) Navigate(url string) error {
	return chromedp.Run(s.ctx, chromedp.Navigate(url))
}

// WaitForSelector waits until the specified CSS selector is present in the DOM.
func (s *Session) WaitForSelector(sel string) error {
	return chromedp.Run(s.ctx, chromedp.WaitReady(sel, chromedp.ByQuery))
}

// GetHTML retrieves the outer HTML of the entire document.
func (s *Session) GetHTML() (string, error) {
	var html string
	err := chromedp.Run(s.ctx, chromedp.OuterHTML("html", &html, chromedp.ByQuery))
	return html, err
}

// Click finds the element by CSS selector and clicks it.
func (s *Session) Click(sel string) error {
	return chromedp.Run(s.ctx, chromedp.Click(sel, chromedp.ByQuery))
}

// Type finds the element by CSS selector and types text into it.
func (s *Session) Type(sel, text string) error {
	return chromedp.Run(s.ctx, chromedp.SendKeys(sel, text, chromedp.ByQuery))
}

// Screenshot captures a full-page screenshot and returns it as a byte slice (PNG).
func (s *Session) Screenshot() ([]byte, error) {
	var buf []byte
	err := chromedp.Run(s.ctx, chromedp.FullScreenshot(&buf, 100))
	return buf, err
}
