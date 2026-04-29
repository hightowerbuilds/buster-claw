package scheduler

import (
	"encoding/json"
	"fmt"
	"os"
	"sync"
	"time"

	"github.com/robfig/cron/v3"
)

// JobType represents the kind of pipeline task to run.
type JobType string

const (
	JobIngest  JobType = "ingest"
	JobAnalyze JobType = "analyze"
	JobFull    JobType = "full"
	JobDigest  JobType = "digest"
	JobCustom  JobType = "custom"
)

// Job represents a single scheduled task.
type Job struct {
	ID        string  `json:"id"`
	Type      JobType `json:"type"`
	Cron      string  `json:"cron"`
	Enabled   bool    `json:"enabled"`
	CustomCmd string  `json:"customCmd,omitempty"`
	DeliverTo string  `json:"deliverTo,omitempty"`
}

// JobState holds transient state for the frontend.
type JobState struct {
	Job
	NextRun   string `json:"nextRun"`
	LastRun   string `json:"lastRun"`
	LastError string `json:"lastError"`
}

type jobStore struct {
	Jobs []Job `json:"jobs"`
}

// Engine coordinates cron-based job execution.
type Engine struct {
	mu           sync.RWMutex
	c            *cron.Cron
	storePath    string
	jobs         map[string]Job
	cronEntryIDs map[string]cron.EntryID
	lastRun      map[string]time.Time
	lastError    map[string]string

	OnIngest  func() error
	OnAnalyze func() error
	OnFull    func() error
	OnDigest  func(deliverTo string) error
	OnCustom  func(cmd string) error
}

// New creates a new scheduler engine backed by the given JSON file.
func New(storePath string) *Engine {
	return &Engine{
		c:            cron.New(),
		storePath:    storePath,
		jobs:         make(map[string]Job),
		cronEntryIDs: make(map[string]cron.EntryID),
		lastRun:      make(map[string]time.Time),
		lastError:    make(map[string]string),
	}
}

// Load reads jobs from disk and schedules them if enabled.
func (e *Engine) Load() error {
	e.mu.Lock()
	defer e.mu.Unlock()

	data, err := os.ReadFile(e.storePath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil // No jobs yet
		}
		return fmt.Errorf("read scheduler store: %w", err)
	}

	var store jobStore
	if err := json.Unmarshal(data, &store); err != nil {
		return fmt.Errorf("parse scheduler store: %w", err)
	}

	for _, j := range store.Jobs {
		e.jobs[j.ID] = j
		if j.Enabled {
			e.scheduleJob(j)
		}
	}
	return nil
}

// Start starts the underlying cron scheduler.
func (e *Engine) Start() {
	e.c.Start()
}

// Stop stops the cron scheduler.
func (e *Engine) Stop() {
	e.c.Stop()
}

// save writes the current jobs to disk. Must hold lock.
func (e *Engine) save() error {
	var store jobStore
	for _, j := range e.jobs {
		store.Jobs = append(store.Jobs, j)
	}
	data, err := json.MarshalIndent(store, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(e.storePath, data, 0644)
}

func (e *Engine) scheduleJob(j Job) {
	id, err := e.c.AddFunc(j.Cron, func() {
		e.runJob(j.ID)
	})
	if err == nil {
		e.cronEntryIDs[j.ID] = id
	}
}

// runJob executes the logic for a job, updating transient state.
func (e *Engine) runJob(jobID string) {
	e.mu.RLock()
	j, ok := e.jobs[jobID]
	e.mu.RUnlock()

	if !ok {
		return
	}

	var err error
	switch j.Type {
	case JobIngest:
		if e.OnIngest != nil {
			err = e.OnIngest()
		}
	case JobAnalyze:
		if e.OnAnalyze != nil {
			err = e.OnAnalyze()
		}
	case JobFull:
		if e.OnFull != nil {
			err = e.OnFull()
		}
	case JobDigest:
		if e.OnDigest != nil {
			err = e.OnDigest(j.DeliverTo)
		}
	case JobCustom:
		if e.OnCustom != nil {
			err = e.OnCustom(j.CustomCmd)
		}
	default:
		err = fmt.Errorf("unknown job type: %s", j.Type)
	}

	e.mu.Lock()
	e.lastRun[jobID] = time.Now()
	if err != nil {
		e.lastError[jobID] = err.Error()
	} else {
		delete(e.lastError, jobID)
	}
	e.mu.Unlock()
}

// AddJob saves a new job and schedules it.
func (e *Engine) AddJob(j Job) error {
	e.mu.Lock()
	defer e.mu.Unlock()

	if _, ok := e.jobs[j.ID]; ok {
		return fmt.Errorf("job %s already exists", j.ID)
	}

	// Validate cron expression
	if _, err := cron.ParseStandard(j.Cron); err != nil {
		return fmt.Errorf("invalid cron expression: %w", err)
	}

	e.jobs[j.ID] = j
	if j.Enabled {
		e.scheduleJob(j)
	}
	return e.save()
}

// UpdateJob updates an existing job.
func (e *Engine) UpdateJob(j Job) error {
	e.mu.Lock()
	defer e.mu.Unlock()

	if _, ok := e.jobs[j.ID]; !ok {
		return fmt.Errorf("job %s not found", j.ID)
	}

	// Validate cron expression
	if _, err := cron.ParseStandard(j.Cron); err != nil {
		return fmt.Errorf("invalid cron expression: %w", err)
	}

	// Remove old cron schedule if active
	if eid, ok := e.cronEntryIDs[j.ID]; ok {
		e.c.Remove(eid)
		delete(e.cronEntryIDs, j.ID)
	}

	e.jobs[j.ID] = j
	if j.Enabled {
		e.scheduleJob(j)
	}
	return e.save()
}

// DeleteJob removes a job.
func (e *Engine) DeleteJob(id string) error {
	e.mu.Lock()
	defer e.mu.Unlock()

	if _, ok := e.jobs[id]; !ok {
		return fmt.Errorf("job %s not found", id)
	}

	if eid, ok := e.cronEntryIDs[id]; ok {
		e.c.Remove(eid)
		delete(e.cronEntryIDs, id)
	}

	delete(e.jobs, id)
	delete(e.lastRun, id)
	delete(e.lastError, id)

	return e.save()
}

// RunNow executes a job immediately in a new goroutine, independent of cron.
func (e *Engine) RunNow(id string) error {
	e.mu.RLock()
	_, ok := e.jobs[id]
	e.mu.RUnlock()

	if !ok {
		return fmt.Errorf("job %s not found", id)
	}

	go e.runJob(id)
	return nil
}

// GetAll returns the transient state for all jobs.
func (e *Engine) GetAll() []JobState {
	e.mu.RLock()
	defer e.mu.RUnlock()

	var states []JobState
	for _, j := range e.jobs {
		state := JobState{Job: j}

		if eid, ok := e.cronEntryIDs[j.ID]; ok {
			entry := e.c.Entry(eid)
			if !entry.Next.IsZero() {
				state.NextRun = entry.Next.Format(time.RFC3339)
			}
		}

		if lr, ok := e.lastRun[j.ID]; ok {
			state.LastRun = lr.Format(time.RFC3339)
		}
		if errStr, ok := e.lastError[j.ID]; ok {
			state.LastError = errStr
		}

		states = append(states, state)
	}
	return states
}
