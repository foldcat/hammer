package acme_test

import "core:bytes"
import json "core:encoding/json"
import "core:os"
import "core:testing"

import address "hammer:core/address"
import edit "hammer:core/edit"
import errs "hammer:core/errs"
import rope "hammer:core/rope"
import txn "hammer:core/txn"

FIXTURE_PATH :: #directory + "/fixtures/acme-edit.json"

Address_Fixture :: struct {
	name:       string,
	input:      string,
	dot:        [2]int,
	expression: string,
	want:       [2]int,
	error:      string,
}

Edit_Fixture :: struct {
	name:         string,
	input:        string,
	dot:          [2]int,
	command:      string,
	want_content: string,
	want:         [2]int,
	error:        string,
}

Fixtures :: struct {
	reference: string,
	offsets:   string,
	addresses: [dynamic]Address_Fixture,
	edits:     [dynamic]Edit_Fixture,
}

fixtures_destroy :: proc(fixtures: ^Fixtures) {
	delete(fixtures.reference, context.allocator)
	delete(fixtures.offsets, context.allocator)
	for fixture in fixtures.addresses {
		delete(fixture.name, context.allocator)
		delete(fixture.input, context.allocator)
		delete(fixture.expression, context.allocator)
		delete(fixture.error, context.allocator)
	}
	delete(fixtures.addresses)
	for fixture in fixtures.edits {
		delete(fixture.name, context.allocator)
		delete(fixture.input, context.allocator)
		delete(fixture.command, context.allocator)
		delete(fixture.want_content, context.allocator)
		delete(fixture.error, context.allocator)
	}
	delete(fixtures.edits)
	fixtures^ = {}
}

load_fixtures :: proc(t: ^testing.T) -> Fixtures {
	fixtures: Fixtures
	data, read_err := os.read_entire_file(FIXTURE_PATH, context.allocator)
	if !testing.expectf(t, read_err == nil, "cannot read %s: %v", FIXTURE_PATH, read_err) {
		return {}
	}
	defer delete(data, context.allocator)
	unmarshal_err := json.unmarshal(data, &fixtures, .JSON, context.allocator)
	if !testing.expectf(t, unmarshal_err == nil, "cannot decode %s: %v", FIXTURE_PATH, unmarshal_err) {
		fixtures_destroy(&fixtures)
		return {}
	}
	return fixtures
}

fixture_error_kind :: proc(name: string) -> errs.Kind {
	switch name {
	case "":
		return .None
	case "NotFound":
		return .NotFound
	case "InvalidInput":
		return .Invalid_Input
	}
	return .Internal
}

init_doc :: proc(t: ^testing.T, doc: ^txn.Doc, text: string) {
	err := txn.doc_init_from_bytes(doc, transmute([]byte)text, {chunk_size = 1}, context.allocator)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
}

expect_content :: proc(t: ^testing.T, doc: ^txn.Doc, name, want: string) {
	got, err := rope.tree_read_all(&doc.tree, {0, rope.tree_byte_count(&doc.tree)}, context.allocator)
	testing.expect(t, errs.ok(err))
	errs.destroy(&err)
	defer delete(got, context.allocator)
	testing.expectf(t, bytes.equal(got, transmute([]byte)want), "%s: content %q, want %q", name, got, want)
}

@(test)
test_acme_address_fixtures :: proc(t: ^testing.T) {
	fixtures := load_fixtures(t)
	defer fixtures_destroy(&fixtures)
	testing.expect(t, len(fixtures.addresses) > 0)
	for fixture in fixtures.addresses {
		doc: txn.Doc
		init_doc(t, &doc, fixture.input)
		defer txn.doc_destroy(&doc)
		expression, parse_err := address.parse(fixture.expression, context.allocator)
		testing.expectf(t, errs.ok(parse_err), "%s: parse failed: %v", fixture.name, parse_err)
		errs.destroy(&parse_err)
		if !errs.ok(parse_err) {
			continue
		}
		dot := rope.Byte_Range{start = fixture.dot[0], end = fixture.dot[1]}
		got, eval_err := address.evaluate(&doc.tree, &expression, dot, context.allocator)
		want_kind := fixture_error_kind(fixture.error)
		testing.expectf(t, eval_err.kind == want_kind, "%s: error %v, want %v", fixture.name, eval_err.kind, want_kind)
		if errs.ok(eval_err) {
			want := rope.Byte_Range{start = fixture.want[0], end = fixture.want[1]}
			testing.expectf(t, got == want, "%s: range [%d, %d), want [%d, %d)", fixture.name, got.start, got.end, want.start, want.end)
		}
		errs.destroy(&eval_err)
	}
}

@(test)
test_acme_edit_fixtures :: proc(t: ^testing.T) {
	fixtures := load_fixtures(t)
	defer fixtures_destroy(&fixtures)
	testing.expect(t, len(fixtures.edits) > 0)
	for fixture in fixtures.edits {
		doc: txn.Doc
		init_doc(t, &doc, fixture.input)
		defer txn.doc_destroy(&doc)
		selection := txn.Selection{anchor = fixture.dot[0], active = fixture.dot[1], affinity = .Right}
		history: address.Regex_History
		program, parse_err := edit.parse(fixture.command, context.allocator)
		testing.expectf(t, errs.ok(parse_err), "%s: parse failed: %v", fixture.name, parse_err)
		errs.destroy(&parse_err)
		if !errs.ok(parse_err) {
			continue
		}
		execute_err := edit.execute(&doc, &selection, &program, &history, 41, context.allocator)
		edit.program_destroy(&program, context.allocator)
		want_kind := fixture_error_kind(fixture.error)
		testing.expectf(t, execute_err.kind == want_kind, "%s: error %v, want %v", fixture.name, execute_err.kind, want_kind)
		errs.destroy(&execute_err)
		expect_content(t, &doc, fixture.name, fixture.want_content)
		testing.expectf(
			t,
			selection.anchor == fixture.want[0] && selection.active == fixture.want[1],
			"%s: dot [%d, %d), want [%d, %d)",
			fixture.name,
			selection.anchor,
			selection.active,
			fixture.want[0],
			fixture.want[1],
		)
	}
}
