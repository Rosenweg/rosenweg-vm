// SPDX-License-Identifier: GPL-3.0-or-later

package main

import (
	"encoding/json"
	"io"
	"sync"
	"time"
)

// Protokoll schreibt jede Aktion als eine JSON-Zeile (systemd: ins Journal).
// Wer, was, an welchem Computer, mit welchem Ergebnis. Nie Tokens, Tickets
// oder Schluessel — die stehen nirgends in diesen Feldern.
type Protokoll struct {
	mu  sync.Mutex
	aus io.Writer
}

type Eintrag struct {
	Zeit     string `json:"zeit"`
	Aktion   string `json:"aktion"`
	Email    string `json:"email,omitempty"`
	Benutzer string `json:"benutzer,omitempty"`
	Peer     string `json:"peer,omitempty"`
	VMID     int    `json:"vmid,omitempty"`
	Ergebnis string `json:"ergebnis"`
	Grund    string `json:"grund,omitempty"`
}

func (p *Protokoll) Schreiben(e Eintrag) {
	e.Zeit = time.Now().UTC().Format(time.RFC3339)
	b, _ := json.Marshal(e)
	p.mu.Lock()
	defer p.mu.Unlock()
	p.aus.Write(append(b, '\n'))
}
