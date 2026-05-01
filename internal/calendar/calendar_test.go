package calendar

import (
	"path/filepath"
	"testing"
)

func TestManagerAddUpdateDeletePersistsEvents(t *testing.T) {
	path := filepath.Join(t.TempDir(), "Library", "calendar.json")
	manager := NewManager(path)

	event, err := manager.Add("2026-05-10", "Planning", "Draft the monthly plan")
	if err != nil {
		t.Fatalf("Add returned error: %v", err)
	}
	if event.ID == "" {
		t.Fatal("expected generated event ID")
	}

	reloaded := NewManager(path)
	if err := reloaded.Load(); err != nil {
		t.Fatalf("Load returned error: %v", err)
	}
	if got := reloaded.All(); len(got) != 1 || got[0].Title != "Planning" {
		t.Fatalf("expected persisted event, got %#v", got)
	}

	if err := reloaded.Update(event.ID, "2026-05-11", "Revised Planning", "Updated notes"); err != nil {
		t.Fatalf("Update returned error: %v", err)
	}
	updated := reloaded.All()[0]
	if updated.Date != "2026-05-11" || updated.Title != "Revised Planning" || updated.Notes != "Updated notes" {
		t.Fatalf("expected updated event, got %#v", updated)
	}

	if err := reloaded.Delete(event.ID); err != nil {
		t.Fatalf("Delete returned error: %v", err)
	}
	if got := reloaded.All(); len(got) != 0 {
		t.Fatalf("expected no events after delete, got %#v", got)
	}
}

func TestManagerRejectsInvalidEvents(t *testing.T) {
	manager := NewManager(filepath.Join(t.TempDir(), "calendar.json"))

	if _, err := manager.Add("05-10-2026", "Planning", ""); err == nil {
		t.Fatal("expected invalid date error")
	}
	if _, err := manager.Add("2026-05-10", "   ", ""); err == nil {
		t.Fatal("expected missing title error")
	}
}
