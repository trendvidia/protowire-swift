// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.

// wiretype records what protobuf-go does with a tag's wire type, so that
// PBWireTypeTests can hold this port to it without a Go toolchain
// (protowire-swift#97, trendvidia/protowire#614).
//
//	cd conformance/wiretype && GOWORK=off go run . --out ../../Tests/ProtowireTests/testdata/wiretype
//
// The inputs are protowire-go's TestUnmarshal_WireTypeMatchesProtobuf
// (encoding/pb/wire_type_test.go, at the protowire-go this go.mod pins):
// every field of conf.All gets one record of every wire type, well formed
// and cut short, alone and inside each message and map field. It writes,
// under --out:
//
//	conf.binpb   conf.proto's descriptor set, for the schema-bound reader
//	table.tsv    one input per line: its hex, protobuf-go's verdict, and on
//	             accept the message protobuf-go read, without its unknown
//	             fields, marshalled deterministically; on reject the error
//	             protowire-go's pb.Unmarshal gives
//
// It refuses to write a table in which protowire-go's verdict differs from
// protobuf-go's on any input, so the error texts are from a reference that
// agrees with the oracle.
package main

import (
	"context"
	"encoding/hex"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"

	"github.com/trendvidia/protocompile"
	"github.com/trendvidia/protowire-go/encoding/pb"
	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protodesc"
	"google.golang.org/protobuf/types/descriptorpb"
	"google.golang.org/protobuf/types/dynamicpb"
)

// conf.proto, as protowire-go's encoding/pb/conformance_test.go writes it.
const confProto = `
syntax = "proto3";
package conf;

message Inner {
  string name = 1;
  int64 n = 2;
}

message All {
  string s = 1;
  int64 i64 = 2;
  int32 i32 = 3;
  uint64 u64 = 4;
  uint32 u32 = 5;
  sint64 z64 = 6;
  sint32 z32 = 7;
  bool b = 8;
  double f64 = 9;
  float f32 = 10;
  bytes buf = 11;
  Inner inner = 12;
  repeated Inner list = 13;
  repeated uint32 nums = 14;
  repeated sint64 zigs = 15;
  repeated float reals = 16;
  repeated string strs = 17;
  map<string, int64> m = 18;
  map<int32, Inner> mm = 19;
  oneof choice {
    string a = 20;
    int64 c = 21;
    Inner d = 22;
  }
  repeated bool flags = 23;
  repeated int64 negs = 24;
  map<bool, bool> bm = 25;
}
`

type confInner struct {
	Name string `protowire:"1"`
	N    int64  `protowire:"2"`
}

// confAll is protowire-go's struct for conf.All, used for its error texts.
type confAll struct {
	S     string               `protowire:"1"`
	I64   int64                `protowire:"2"`
	I32   int32                `protowire:"3"`
	U64   uint64               `protowire:"4"`
	U32   uint32               `protowire:"5"`
	Z64   int64                `protowire:"6,zigzag"`
	Z32   int32                `protowire:"7,zigzag"`
	B     bool                 `protowire:"8"`
	F64   float64              `protowire:"9"`
	F32   float32              `protowire:"10"`
	Buf   []byte               `protowire:"11"`
	Inner *confInner           `protowire:"12"`
	List  []*confInner         `protowire:"13"`
	Nums  []uint32             `protowire:"14"`
	Zigs  []int64              `protowire:"15,zigzag"`
	Reals []float32            `protowire:"16"`
	Strs  []string             `protowire:"17"`
	M     map[string]int64     `protowire:"18"`
	MM    map[int32]*confInner `protowire:"19"`
	A     string               `protowire:"20"`
	C     int64                `protowire:"21"`
	D     *confInner           `protowire:"22"`
	Flags []bool               `protowire:"23"`
	Negs  []int64              `protowire:"24"`
	BM    map[bool]bool        `protowire:"25"`
}

// wireRecords returns single records for field num: every wire type, each
// with a well-formed value and a value cut short.
func wireRecords(num protowire.Number) [][]byte {
	tag := func(typ protowire.Type) []byte { return protowire.AppendTag(nil, num, typ) }
	cat := func(parts ...[]byte) []byte {
		var b []byte
		for _, p := range parts {
			b = append(b, p...)
		}
		return b
	}
	return [][]byte{
		cat(tag(protowire.VarintType), []byte{0x01}),
		cat(tag(protowire.VarintType), []byte{0x80}), // cut short
		cat(tag(protowire.Fixed64Type), []byte{1, 0, 0, 0, 0, 0, 0, 0}),
		cat(tag(protowire.Fixed64Type), []byte{1, 0, 0}), // cut short
		cat(tag(protowire.BytesType), []byte{0x00}),
		cat(tag(protowire.BytesType), []byte{0x01, 0x01}),
		cat(tag(protowire.BytesType), []byte{0x01}), // cut short
		cat(tag(protowire.StartGroupType), tag(protowire.EndGroupType)),
		tag(protowire.StartGroupType), // never ended
		tag(protowire.EndGroupType),   // ends nothing
		cat(tag(protowire.Fixed32Type), []byte{1, 0, 0, 0}),
		cat(tag(protowire.Fixed32Type), []byte{1, 0}), // cut short
		cat(protowire.AppendVarint(nil, uint64(num)<<3|6), []byte{0x01}),
		cat(protowire.AppendVarint(nil, uint64(num)<<3|7), []byte{0x01}),
	}
}

// inputs is every record for every field of conf.All, alone and carried
// inside each message field (12, 13, 22: Inner's fields 1, 2 and an
// unknown 3) and map field (18, 19, 25: key 1, value 2, unknown 3).
func inputs() [][]byte {
	var out [][]byte
	for num := protowire.Number(1); num <= 25; num++ {
		out = append(out, wireRecords(num)...)
	}
	for _, outer := range []protowire.Number{12, 13, 18, 19, 22, 25} {
		for inner := protowire.Number(1); inner <= 3; inner++ {
			for _, rec := range wireRecords(inner) {
				b := protowire.AppendTag(nil, outer, protowire.BytesType)
				out = append(out, protowire.AppendBytes(b, rec))
			}
		}
	}
	// A matching record after a mismatched one: the mismatch leaves the
	// field as it was, and the match still sets it.
	for _, h := range []string{
		"0a0161" + "0801",     // s: "a", then s as a varint
		"1007" + "1501000000", // i64: 7, then i64 as fixed32
		"720101" + "7001",     // nums packed [1], then nums as a varint
		"7001" + "7501000000", // nums [1], then nums as fixed32
	} {
		b, err := hex.DecodeString(h)
		if err != nil {
			log.Fatal(err)
		}
		out = append(out, b)
	}
	return out
}

func main() {
	out := flag.String("out", "", "directory to write conf.binpb and table.tsv into")
	flag.Parse()
	if *out == "" {
		log.Fatal("--out is required")
	}

	comp := protocompile.Compiler{Resolver: protocompile.WithStandardImports(&protocompile.SourceResolver{
		Accessor: protocompile.SourceAccessorFromMap(map[string]string{"conf.proto": confProto}),
	})}
	files, err := comp.Compile(context.Background(), "conf.proto")
	if err != nil {
		log.Fatal(err)
	}
	md := files[0].Messages().ByName("All")

	set := &descriptorpb.FileDescriptorSet{File: []*descriptorpb.FileDescriptorProto{protodesc.ToFileDescriptorProto(files[0])}}
	setBytes, err := proto.MarshalOptions{Deterministic: true}.Marshal(set)
	if err != nil {
		log.Fatal(err)
	}

	var table strings.Builder
	table.WriteString("# Written by conformance/wiretype; do not edit. Columns: input hex, protobuf-go's verdict,\n")
	table.WriteString("# then on accept the known fields protobuf-go read, re-marshalled, and on reject protowire-go's error.\n")
	accepted, rejected := 0, 0
	for _, in := range inputs() {
		oracle := dynamicpb.NewMessage(md)
		oracleErr := proto.UnmarshalOptions{DiscardUnknown: true}.Unmarshal(in, oracle)
		var ref confAll
		refErr := pb.Unmarshal(in, &ref)
		if (oracleErr == nil) != (refErr == nil) {
			log.Fatalf("%x: protobuf-go says %v, protowire-go says %v", in, oracleErr, refErr)
		}
		if oracleErr != nil {
			rejected++
			// protobuf-go writes "proto:" and a no-break space in some
			// binaries and a plain space in others, by a hash of the binary;
			// the plain one keeps the table the same from build to build.
			fmt.Fprintf(&table, "%x\treject\t%s\n", in, strings.ReplaceAll(refErr.Error(), "\u00a0", " "))
			continue
		}
		accepted++
		known, err := proto.MarshalOptions{Deterministic: true}.Marshal(oracle)
		if err != nil {
			log.Fatal(err)
		}
		fmt.Fprintf(&table, "%x\taccept\t%x\n", in, known)
	}

	if err := os.MkdirAll(*out, 0o755); err != nil {
		log.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(*out, "conf.binpb"), setBytes, 0o644); err != nil {
		log.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(*out, "table.tsv"), []byte(table.String()), 0o644); err != nil {
		log.Fatal(err)
	}
	fmt.Printf("%d inputs: protobuf-go accepts %d, rejects %d\n", accepted+rejected, accepted, rejected)
}
