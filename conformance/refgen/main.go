// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.

// refgen records what protowire-go does with every document in the spec
// repo's testdata/, so that this port can be compared with the reference
// without a Go toolchain. See conformance/README.md.
//
//	refgen --spec ../protowire --out Tests/ProtowireTests/testdata/conformance
//
// It writes, under --out:
//
//	corpus/<suite>/<file>       the inputs, copied from the spec repo
//	descriptors/<suite>.binpb   a FileDescriptorSet with imports
//	reference.jsonl             one Record per document, sorted
//	provenance.json             the spec and reference revisions
//
// Only protowire-go decides a verdict here. A fixture's leading comment is
// the spec's statement of what should happen, and the spec repo's own tests
// hold the reference to it.
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime/debug"
	"sort"
	"strings"

	"github.com/trendvidia/protocompile"
	"github.com/trendvidia/protocompile/linker"
	"github.com/trendvidia/protowire-go/encoding/pxf"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protodesc"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"
	"google.golang.org/protobuf/types/descriptorpb"
	"google.golang.org/protobuf/types/dynamicpb"
)

// suite names one directory of testdata/ and the schemas its documents bind
// against, relative to testdata/.
type suite struct {
	dir     string
	protos  []string
	message string // for a document with neither @type nor @dataset
}

var suites = []suite{
	{dir: "annotations", protos: []string{"annotations/settings.proto"}, message: "settings.v1.Settings"},
	{dir: "any", protos: []string{"any/any.proto"}},
	{dir: "bigfloat", protos: []string{"bigfloat/bigfloat.proto"}, message: "bf.v1.H"},
	{dir: "blocks", protos: []string{"blocks/blocks.proto"}},
	{dir: "dataset", protos: []string{"test.proto", "dataset/paths.proto"}},
	{dir: "duplicates", protos: []string{"duplicates/duplicates.proto"}},
	{dir: "duration", protos: []string{"duration/duration.proto"}},
	{dir: "keyed", protos: []string{"keyed/keyed.proto"}},
	{dir: "map-keys", protos: []string{"map-keys/bool-keys.proto"}},
	{dir: "nulls", protos: []string{"nulls/nulls.proto", "nulls/nulls_proto2.proto", "nulls/nulls_editions.proto"}},
	{dir: "repeated", protos: []string{"test.proto"}},
	{dir: "strings", protos: []string{"strings/strings.proto"}},
}

// Record is one document and what the reference made of it. Bytes and text
// are lists because a dataset yields one message per row.
type Record struct {
	Suite       string   `json:"suite"`
	File        string   `json:"file"`
	Input       string   `json:"input"` // "pxf" or "pb"
	Message     string   `json:"message,omitempty"`
	Parse       string   `json:"parse"` // "accept", "reject", or "" for pb input
	ParseError  string   `json:"parse_error,omitempty"`
	Decode      string   `json:"decode"` // "accept", "reject", or "" when unbound
	DecodeError string   `json:"decode_error,omitempty"`
	PB          []string `json:"pb,omitempty"`
	Text        []string `json:"text,omitempty"`
	Format      *string  `json:"format,omitempty"`
}

// registry holds a suite's schemas, linked from the descriptor-set bytes the
// corpus ships, so the reference reads the schema this port reads.
type registry struct {
	files *protoregistry.Files
	set   []byte
}

func (r registry) find(name string) protoreflect.MessageDescriptor {
	d, err := r.files.FindDescriptorByName(protoreflect.FullName(name))
	if err != nil {
		return nil
	}
	m, _ := d.(protoreflect.MessageDescriptor)
	return m
}

// resolver is the spec tests' Any resolver: the message named after the
// URL's last "/".
type resolver struct{ reg registry }

func (r resolver) FindMessageByURL(url string) (protoreflect.MessageDescriptor, error) {
	name := url[strings.LastIndex(url, "/")+1:]
	if d := r.reg.find(name); d != nil {
		return d, nil
	}
	return nil, fmt.Errorf("unresolved type URL %q", url)
}

func compile(root, spec string, protos []string) registry {
	c := protocompile.Compiler{
		Resolver: protocompile.WithStandardImports(&protocompile.SourceResolver{
			ImportPaths: []string{root, filepath.Join(spec, "proto")},
		}),
	}
	files, err := c.Compile(context.Background(), protos...)
	if err != nil {
		log.Fatalf("compile %v: %v", protos, err)
	}
	set, err := proto.MarshalOptions{Deterministic: true}.Marshal(descriptorSet(root, files))
	if err != nil {
		log.Fatal(err)
	}
	var fds descriptorpb.FileDescriptorSet
	if err := proto.Unmarshal(set, &fds); err != nil {
		log.Fatal(err)
	}
	linked, err := protodesc.NewFiles(&fds)
	if err != nil {
		log.Fatalf("link %v: %v", protos, err)
	}
	return registry{files: linked, set: set}
}

// descriptorSet is the import closure of files, dependencies first.
func descriptorSet(root string, files linker.Files) *descriptorpb.FileDescriptorSet {
	set := &descriptorpb.FileDescriptorSet{}
	seen := map[string]bool{}
	var add func(protoreflect.FileDescriptor)
	add = func(f protoreflect.FileDescriptor) {
		if seen[f.Path()] {
			return
		}
		seen[f.Path()] = true
		imports := f.Imports()
		for i := 0; i < imports.Len(); i++ {
			add(imports.Get(i).FileDescriptor)
		}
		fd := protodesc.ToFileDescriptorProto(f)
		if fd.GetSyntax() == "editions" {
			fd.Edition = edition(root, f.Path())
		}
		set.File = append(set.File, fd)
	}
	for _, f := range files {
		add(f)
	}
	return set
}

var editionLine = regexp.MustCompile(`(?m)^edition = "(\d+)";`)

// edition reads a file's edition from its source: protodesc leaves it out of
// a descriptor that protocompile linked, and an editions file with no edition
// does not link.
func edition(root, path string) *descriptorpb.Edition {
	src, err := os.ReadFile(filepath.Join(root, path))
	if err != nil {
		log.Fatal(err)
	}
	m := editionLine.FindSubmatch(src)
	if m == nil {
		log.Fatalf("%s: no edition line", path)
	}
	v, ok := descriptorpb.Edition_value["EDITION_"+string(m[1])]
	if !ok {
		log.Fatalf("%s: unknown edition %s", path, m[1])
	}
	return descriptorpb.Edition(v).Enum()
}

func marshalPB(m proto.Message) string {
	b, err := proto.MarshalOptions{Deterministic: true}.Marshal(m)
	if err != nil {
		log.Fatalf("marshal: %v", err)
	}
	return hex.EncodeToString(b)
}

// appendMessage records m's bytes, and its text unless the reference
// refuses to write it, which is a fact about the reference and is recorded
// as an empty string.
func appendMessage(r *Record, m proto.Message, res pxf.TypeResolver) {
	r.PB = append(r.PB, marshalPB(m))
	text, err := pxf.MarshalOptions{TypeResolver: res}.Marshal(m)
	if err != nil {
		text = nil
	}
	r.Text = append(r.Text, string(text))
}

func runPXF(s suite, reg registry, file string, data []byte) Record {
	r := Record{Suite: s.dir, File: file, Input: "pxf"}
	res := resolver{reg}
	opts := pxf.UnmarshalOptions{TypeResolver: res}
	doc, err := pxf.Parse(data)
	if err != nil {
		r.Parse, r.ParseError = "reject", err.Error()
	} else {
		r.Parse = "accept"
		f := string(pxf.FormatDocument(doc))
		r.Format = &f
	}

	if err == nil && len(doc.Datasets) > 0 {
		r.Decode = "accept"
		for _, ds := range doc.Datasets {
			md := reg.find(ds.Type)
			if md == nil {
				r.Decode, r.DecodeError, r.PB, r.Text = "", "", nil, nil
				return r
			}
			r.Message = ds.Type
			for _, row := range ds.Rows {
				m := dynamicpb.NewMessage(md)
				if err := opts.BindRow(m, ds.Columns, row); err != nil {
					r.Decode, r.DecodeError, r.PB, r.Text = "reject", err.Error(), nil, nil
					return r
				}
				appendMessage(&r, m, res)
			}
		}
		return r
	}

	name := s.message
	if err == nil && doc.TypeURL != "" {
		name = doc.TypeURL
	} else if t := leadingType(data); t != "" {
		name = t
	}
	md := reg.find(name)
	if md == nil {
		return r
	}
	r.Message = name
	// The full decode is the one that applies (pxf.required) and (pxf.default);
	// the plain one leaves both to the caller.
	m, _, derr := opts.UnmarshalFullDescriptor(data, md)
	if derr != nil {
		r.Decode, r.DecodeError = "reject", derr.Error()
		return r
	}
	r.Decode = "accept"
	appendMessage(&r, m, res)
	return r
}

// leadingType reads the @type directive of a document that did not parse.
func leadingType(data []byte) string {
	sc := bufio.NewScanner(bytes.NewReader(data))
	for sc.Scan() {
		if rest, ok := strings.CutPrefix(strings.TrimSpace(sc.Text()), "@type "); ok {
			return strings.TrimSpace(rest)
		}
	}
	return ""
}

func runPB(dir, file, message string, reg registry, data []byte) Record {
	r := Record{Suite: dir, File: file, Input: "pb", Message: message}
	md := reg.find(message)
	if md == nil {
		log.Fatalf("%s/%s: no message %s", dir, file, message)
	}
	m := dynamicpb.NewMessage(md)
	if err := proto.Unmarshal(data, m); err != nil {
		r.Decode, r.DecodeError = "reject", err.Error()
		return r
	}
	r.Decode = "accept"
	appendMessage(&r, m, resolver{reg})
	return r
}

func copyInto(out, suite, file string, data []byte) {
	p := filepath.Join(out, "corpus", suite, file)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		log.Fatal(err)
	}
	if err := os.WriteFile(p, data, 0o644); err != nil {
		log.Fatal(err)
	}
}

func writeDescriptors(out, name string, reg registry) {
	p := filepath.Join(out, "descriptors", name+".binpb")
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		log.Fatal(err)
	}
	if err := os.WriteFile(p, reg.set, 0o644); err != nil {
		log.Fatal(err)
	}
}

func gitHead(dir string) string {
	b, err := exec.Command("git", "-C", dir, "rev-parse", "HEAD").Output()
	if err != nil {
		return "unknown"
	}
	return strings.TrimSpace(string(b))
}

func main() {
	spec := flag.String("spec", "../protowire", "protowire spec repo checkout")
	out := flag.String("out", "Tests/ProtowireTests/testdata/conformance", "output directory")
	rev := flag.String("spec-rev", "", "spec revision to record, when --spec is not a git checkout")
	flag.Parse()
	testdata := filepath.Join(*spec, "testdata")

	regs := make(map[string]registry, len(suites))
	for _, s := range suites {
		regs[s.dir] = compile(testdata, *spec, s.protos)
	}
	textReg := compile(filepath.Join(testdata, "text"), *spec, []string{"text.proto"})

	for _, sub := range []string{"corpus", "descriptors"} {
		if err := os.RemoveAll(filepath.Join(*out, sub)); err != nil {
			log.Fatal(err)
		}
	}

	var records []Record
	for _, s := range suites {
		reg := regs[s.dir]
		writeDescriptors(*out, s.dir, reg)
		docs, err := filepath.Glob(filepath.Join(testdata, s.dir, "*.pxf"))
		if err != nil {
			log.Fatal(err)
		}
		for _, p := range docs {
			data, err := os.ReadFile(p)
			if err != nil {
				log.Fatal(err)
			}
			file := filepath.Base(p)
			copyInto(*out, s.dir, file, data)
			records = append(records, runPXF(s, reg, file, data))
		}
		if s.dir == "bigfloat" {
			// An enc- case is a message and the text an encoder must write.
			encs, err := filepath.Glob(filepath.Join(testdata, s.dir, "enc-*.binpb"))
			if err != nil {
				log.Fatal(err)
			}
			for _, p := range encs {
				data, err := os.ReadFile(p)
				if err != nil {
					log.Fatal(err)
				}
				file := filepath.Base(p)
				copyInto(*out, s.dir, file, data)
				records = append(records, runPB(s.dir, file, s.message, reg, data))
			}
		}
	}

	// The marshaller's goldens (protowire#503): each case is protobuf bytes,
	// and the reference's text for them is the golden the spec holds.
	writeDescriptors(*out, "text", textReg)
	cases, err := filepath.Glob(filepath.Join(testdata, "text", "cases", "*.binpb"))
	if err != nil {
		log.Fatal(err)
	}
	for _, p := range cases {
		data, err := os.ReadFile(p)
		if err != nil {
			log.Fatal(err)
		}
		file := filepath.Base(p)
		copyInto(*out, "text", file, data)
		records = append(records, runPB("text", file, "text.v1."+strings.SplitN(file, ".", 2)[0], textReg, data))
	}

	// A record that skipped the annotations looks like any other, so prove the
	// reference applied them: this document only fails on (pxf.required).
	for _, r := range records {
		if r.Suite == "annotations" && r.File == "missing-required.pxf" && r.Decode != "reject" {
			log.Fatal("the reference accepted missing-required.pxf: (pxf.required) was not applied")
		}
	}

	sort.Slice(records, func(i, j int) bool {
		if records[i].Suite != records[j].Suite {
			return records[i].Suite < records[j].Suite
		}
		return records[i].File < records[j].File
	})
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	for _, r := range records {
		if err := enc.Encode(r); err != nil {
			log.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(*out, "reference.jsonl"), buf.Bytes(), 0o644); err != nil {
		log.Fatal(err)
	}

	specRev := *rev
	if specRev == "" {
		specRev = gitHead(*spec)
	}
	goVersion := "unknown"
	if bi, ok := debug.ReadBuildInfo(); ok {
		for _, d := range bi.Deps {
			if d.Path == "github.com/trendvidia/protowire-go" {
				goVersion = d.Version
			}
		}
	}
	prov, err := json.MarshalIndent(map[string]any{
		"protowire":    specRev,
		"protowire-go": goVersion,
		"documents":    len(records),
	}, "", "  ")
	if err != nil {
		log.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(*out, "provenance.json"), append(prov, '\n'), 0o644); err != nil {
		log.Fatal(err)
	}
	fmt.Printf("%d documents across %d suites\n", len(records), len(suites)+1)
}
