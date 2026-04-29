package browser

import (
	"context"
	"fmt"
	"time"

	"github.com/chromedp/cdproto/network"
	"github.com/chromedp/chromedp"
)

// LightPandaEngine implements the Engine interface for Light Panda.
type LightPandaEngine struct {
	Timeout time.Duration
}

func NewLightPandaEngine() *LightPandaEngine {
	return &LightPandaEngine{Timeout: 30 * time.Second}
}

type lpSession struct {
	ctx    context.Context
	cancel context.CancelFunc
}

func (e *LightPandaEngine) NewSession(parentCtx context.Context) (Session, error) {
	// Connect to existing Light Panda server
	ctx, cancel := chromedp.NewRemoteAllocator(parentCtx, "ws://127.0.0.1:9222")
	taskCtx, taskCancel := chromedp.NewContext(ctx)

	timeoutCtx, timeoutCancel := context.WithTimeout(taskCtx, e.Timeout)

	combinedCancel := func() {
		timeoutCancel()
		taskCancel()
		cancel()
	}

	return &lpSession{
		ctx:    timeoutCtx,
		cancel: combinedCancel,
	}, nil
}

func (s *lpSession) Close() { s.cancel() }

func (s *lpSession) SetCookies(cookies []*network.CookieParam) error {
	return chromedp.Run(s.ctx, network.SetCookies(cookies))
}

func (s *lpSession) Navigate(url string) error {
	randomDelay()
	return chromedp.Run(s.ctx, chromedp.Navigate(url))
}

func (s *lpSession) WaitForSelector(sel string) error {
	return chromedp.Run(s.ctx, chromedp.WaitReady(sel, chromedp.ByQuery))
}

func (s *lpSession) GetHTML() (string, error) {
	var html string
	err := chromedp.Run(s.ctx, chromedp.OuterHTML("html", &html, chromedp.ByQuery))
	return html, err
}

func (s *lpSession) Click(sel string) error {
	randomDelay()
	return chromedp.Run(s.ctx, chromedp.Click(sel, chromedp.ByQuery))
}

func (s *lpSession) Type(sel, text string) error {
	randomDelay()
	return chromedp.Run(s.ctx, chromedp.SendKeys(sel, text, chromedp.ByQuery))
}

func (s *lpSession) Screenshot() ([]byte, error) {
	return nil, fmt.Errorf("screenshot not supported by Light Panda")
}
