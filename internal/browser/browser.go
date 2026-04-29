package browser

import (
	"context"
	"math/rand"
	"os"
	"time"

	"github.com/chromedp/cdproto/network"
	"github.com/chromedp/chromedp"
)

// Engine defines the capabilities expected from a browser implementation.
type Engine interface {
	NewSession(parentCtx context.Context) (Session, error)
}

// Session represents an active browser tab and its underlying process.
type Session interface {
	Close()
	SetCookies(cookies []*network.CookieParam) error
	Navigate(url string) error
	WaitForSelector(sel string) error
	GetHTML() (string, error)
	Click(sel string) error
	Type(sel, text string) error
	Screenshot() ([]byte, error)
}

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

func randomDelay() {
	time.Sleep(time.Duration(rand.Intn(1000)+500) * time.Millisecond)
}

// ChromeEngine implements the Engine interface using chromedp.
type ChromeEngine struct {
	Timeout time.Duration
}

func NewChromeEngine() *ChromeEngine {
	return &ChromeEngine{Timeout: 30 * time.Second}
}

type chromeSession struct {
	ctx    context.Context
	cancel context.CancelFunc
}

func (e *ChromeEngine) NewSession(parentCtx context.Context) (Session, error) {
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

	timeoutCtx, timeoutCancel := context.WithTimeout(taskCtx, e.Timeout)

	combinedCancel := func() {
		timeoutCancel()
		taskCancel()
		allocCancel()
	}

	return &chromeSession{
		ctx:    timeoutCtx,
		cancel: combinedCancel,
	}, nil
}

func (s *chromeSession) Close() { s.cancel() }

func (s *chromeSession) SetCookies(cookies []*network.CookieParam) error {
	return chromedp.Run(s.ctx, network.SetCookies(cookies))
}

func (s *chromeSession) Navigate(url string) error {
	randomDelay()
	return chromedp.Run(s.ctx, chromedp.Navigate(url))
}

func (s *chromeSession) WaitForSelector(sel string) error {
	return chromedp.Run(s.ctx, chromedp.WaitReady(sel, chromedp.ByQuery))
}

func (s *chromeSession) GetHTML() (string, error) {
	var html string
	err := chromedp.Run(s.ctx, chromedp.OuterHTML("html", &html, chromedp.ByQuery))
	return html, err
}

func (s *chromeSession) Click(sel string) error {
	randomDelay()
	return chromedp.Run(s.ctx, chromedp.Click(sel, chromedp.ByQuery))
}

func (s *chromeSession) Type(sel, text string) error {
	randomDelay()
	return chromedp.Run(s.ctx, chromedp.SendKeys(sel, text, chromedp.ByQuery))
}

func (s *chromeSession) Screenshot() ([]byte, error) {
	var buf []byte
	err := chromedp.Run(s.ctx, chromedp.FullScreenshot(&buf, 100))
	return buf, err
}
