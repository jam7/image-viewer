#!/usr/bin/env python3
"""Stop private data from reaching this public repository.

The repository is public; the developer's real library (share layout, work
titles, server ids) is not. Rules in CLAUDE.md were not enough -- real paths
leaked several times, in separate sessions, because test data gets written by
copying whatever was on screen in a device log. This turns the rule into a
gate that does not depend on anyone remembering it.

Two kinds of check:

* Structural -- absolute home paths, private IPs, long numeric ids. These
  patterns are wrong wherever they appear, so every scanned file gets them.

* Vocabulary (the important one) -- in test data and documentation examples,
  anything that looks like content (a path with separators, a media filename,
  any CJK text) must be built from tools/test-vocabulary.txt. A denylist can
  only catch names someone thought to list; a vocabulary catches the work
  title nobody knew about, which is exactly the case that keeps happening.

An optional exact denylist is read from notes/private-patterns.txt when that
file exists. It lists real names, so it lives in the private notes repository
and never in this one -- a list of things that must not leak is itself the
worst thing to leak.

Usage:
  check-private.py --staged            what is about to be committed
  check-private.py --range A..B        every revision in a range, and messages
  check-private.py --all-history       every revision that exists
  check-private.py --worktree          the files on disk right now
"""
import argparse
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VOCAB_FILE = os.path.join(ROOT, 'tools', 'test-vocabulary.txt')
DENYLIST_FILE = os.path.join(ROOT, 'notes', 'private-patterns.txt')

# Files whose string literals and code examples must use the vocabulary.
DATA_SCOPE = (
    re.compile(r'(^|/)test/.*\.dart$'),
    re.compile(r'(^|/)docs/.*\.md$'),
    re.compile(r'^[^/]*\.md$'),
)
# Everything scanned at all. lib/ is here for the structural checks only: its
# Japanese UI strings are legitimate content, not test data.
SCAN_SCOPE = DATA_SCOPE + (
    re.compile(r'(^|/)lib/.*\.dart$'),
    re.compile(r'(^|/)packages/.*\.dart$'),
)

CJK = re.compile(r'[぀-ヿ㐀-䶿一-鿿]')
# `$e\n$st` in a logging example is one string, not a two-segment path. A real
# path carries a dot, a slash or a drive colon; an escape sequence does not.
ESCAPE_NOT_PATH = re.compile(r'^[^/:.]*\\[nrt0v][^/:.]*$')
MEDIA = re.compile(r'\.(pdf|zip|cbz|rar|jpe?g|png|gif|webp|mp4|mkv|avi|webm|mov|wmv|ts|m4v)$', re.I)

STRUCTURAL = [
    # Case-sensitive on purpose: `/Home/End` is a pair of keys and
    # `pixiv.net/users/123` is a URL, and both matched when it was not.
    (re.compile(r'(?<![\w/.])/home/[a-z0-9_.-]+'), 'absolute home path'),
    (re.compile(r'(?<![\w/.])/Users/[A-Za-z0-9_.-]+'), 'absolute home path'),
    (re.compile(r'[A-Z]:\\\\?Users\\\\?[a-z0-9_.-]+', re.I), 'absolute home path'),
    (re.compile(r'\b192\.168\.\d{1,3}\.\d{1,3}\b'), 'private IP address'),
    (re.compile(r'\b10\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'), 'private IP address'),
    (re.compile(r'\b172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}\b'), 'private IP address'),
    (re.compile(r'(?<![\d.])\d{12,}(?![\d.])'), 'long numeric id (SMB config id?)'),
]

# Dart string literals are pure data, so all of one is worth looking at.
DART_LITERAL = re.compile(r"""(r?)'([^'\n\\]*(?:\\.[^'\n\\]*)*)'|(r?)"([^"\n\\]*(?:\\.[^"\n\\]*)*)\"""")

# Markdown is mostly Japanese prose, so whole lines say nothing. Only tokens
# shaped like a path or a file name are data: a backslash-separated path, or
# anything ending in a media extension. Both forms of the leak this exists to
# stop (`<share>\<work>.pdf`) are caught by either half.
MD_BREAK = r'\s`\'"()<>|,、。（）「」'
MD_TOKEN = re.compile(
    rf'[^{MD_BREAK}]*(?:\\[^{MD_BREAK}\\]+)+'
    rf'|[^{MD_BREAK}]+\.(?:pdf|zip|cbz|rar|jpe?g|png|gif|webp|mp4|mkv|avi|webm|mov|wmv|m4v)\b',
    re.I,
)


def load_vocabulary():
    """Allowed path segments and file names, plus regexes for generated ones."""
    tokens, patterns = set(), []
    if not os.path.exists(VOCAB_FILE):
        return tokens, patterns
    with open(VOCAB_FILE, encoding='utf-8') as f:
        for line in f:
            # '#' is a comment only at the start or after a space: it is also
            # a legal character in a path segment, and `b#c` is a test case.
            line = re.sub(r'(?:^|\s)#.*$', '', line).strip()
            if not line:
                continue
            if line.startswith('~'):
                patterns.append(re.compile(line[1:]))
            else:
                tokens.add(line)
    return tokens, patterns


def load_denylist():
    if not os.path.exists(DENYLIST_FILE):
        return []
    out = []
    with open(DENYLIST_FILE, encoding='utf-8') as f:
        for line in f:
            line = re.sub(r'(?:^|\s)#.*$', '', line).strip()
            if line:
                out.append(line)
    return out


def looks_like_content(text, cjk_counts=True):
    """Whether this span is the kind of thing real data hides in.

    [cjk_counts] is false for Markdown, which is written in Japanese: there,
    only a path-shaped or media-named token can be data.
    """
    if cjk_counts and CJK.search(text):
        return True
    if MEDIA.search(text):
        return True
    if ESCAPE_NOT_PATH.match(text):
        return False
    return bool(re.search(r'[^\s\\/]\\[^\s\\/]', text))


def vocabulary_ok(text, tokens, patterns):
    if any(p.search(text) for p in patterns):
        return True
    segments = [s for s in re.split(r'[\\/]+', text) if s]
    if not segments:
        return True
    return all(
        s in tokens or any(p.fullmatch(s) for p in patterns) for s in segments
    )


def literals_of(path, content):
    """Every span in this file that is data rather than prose."""
    if path.endswith('.dart'):
        for m in DART_LITERAL.finditer(content):
            raw = bool(m.group(1) or m.group(3))
            text = m.group(2) if m.group(2) is not None else m.group(4)
            if not text:
                continue
            if not raw:
                # Escapes are not path separators: `$e\n$st` is one line of
                # log, not a two-segment path.
                text = re.sub(r'\\(.)', r'\1', text)
            yield content[:m.start()].count('\n') + 1, text
    elif path.endswith('.md'):
        for lineno, line in enumerate(content.split('\n'), 1):
            for m in MD_TOKEN.finditer(line):
                if m.group(0).strip():
                    yield lineno, m.group(0).strip()


def check_content(path, content, tokens, patterns, denylist):
    problems = []
    in_data_scope = any(p.search(path) for p in DATA_SCOPE)

    for lineno, line in enumerate(content.split('\n'), 1):
        for rx, why in STRUCTURAL:
            m = rx.search(line)
            if m and not vocabulary_ok(m.group(0), tokens, patterns):
                problems.append((path, lineno, why, m.group(0)))
        for term in denylist:
            if term.lower() in line.lower():
                problems.append((path, lineno, 'known private name', term))

    if in_data_scope:
        cjk_counts = not path.endswith('.md')
        for lineno, text in literals_of(path, content):
            if looks_like_content(text, cjk_counts) and \
                    not vocabulary_ok(text, tokens, patterns):
                problems.append((path, lineno, 'not in the test vocabulary', text))
    return problems


def git(*args):
    return subprocess.run(['git'] + list(args), cwd=ROOT, capture_output=True,
                          text=True, errors='replace').stdout


def in_scope(path):
    return any(p.search(path) for p in SCAN_SCOPE)


def check_staged(tokens, patterns, denylist):
    names = git('diff', '--cached', '--name-only', '--diff-filter=ACMR').split('\n')
    problems = []
    for path in filter(None, names):
        if not in_scope(path):
            continue
        content = git('show', ':' + path)
        problems += check_content(path, content, tokens, patterns, denylist)
    return problems


def check_worktree(tokens, patterns, denylist):
    problems = []
    for path in filter(None, git('ls-files').split('\n')):
        if not in_scope(path):
            continue
        full = os.path.join(ROOT, path)
        if not os.path.exists(full):
            continue
        with open(full, encoding='utf-8', errors='replace') as f:
            problems += check_content(path, f.read(), tokens, patterns, denylist)
    return problems


def check_revisions(revs, tokens, patterns, denylist):
    """Every blob that ever existed shows up as changed in some revision, so
    scanning each revision's own changes covers the whole history once."""
    problems = []
    for rev in revs:
        message = git('log', '-1', '--format=%B', rev)
        for lineno, line in enumerate(message.split('\n'), 1):
            for term in denylist:
                if term.lower() in line.lower():
                    problems.append((rev[:9] + ' (message)', lineno,
                                     'known private name', term))
            for rx, why in STRUCTURAL:
                m = rx.search(line)
                if m and not vocabulary_ok(m.group(0), tokens, patterns):
                    problems.append((rev[:9] + ' (message)', lineno, why, m.group(0)))
            for m in MD_TOKEN.finditer(line):
                token = m.group(0).strip()
                if looks_like_content(token, False) and \
                        not vocabulary_ok(token, tokens, patterns):
                    problems.append((rev[:9] + ' (message)', lineno,
                                     'not in the test vocabulary', token))

        changed = git('diff-tree', '-r', '--no-commit-id', '--name-only',
                      '--diff-filter=ACMR', rev).split('\n')
        for path in filter(None, changed):
            if not in_scope(path):
                continue
            content = git('show', f'{rev}:{path}')
            for p, lineno, why, hit in check_content(
                    path, content, tokens, patterns, denylist):
                problems.append((f'{rev[:9]} {p}', lineno, why, hit))
    return problems


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument('--staged', action='store_true')
    g.add_argument('--worktree', action='store_true')
    g.add_argument('--range')
    g.add_argument('--all-history', action='store_true')
    args = ap.parse_args()

    tokens, patterns = load_vocabulary()
    denylist = load_denylist()

    if args.staged:
        problems = check_staged(tokens, patterns, denylist)
    elif args.worktree:
        problems = check_worktree(tokens, patterns, denylist)
    else:
        spec = ['--all'] if args.all_history else [args.range]
        revs = [r for r in git('rev-list', *spec).split('\n') if r]
        problems = check_revisions(revs, tokens, patterns, denylist)

    if not problems:
        return 0

    print('Private data check failed:\n', file=sys.stderr)
    for path, lineno, why, hit in problems:
        print(f'  {path}:{lineno}: {why}: {hit}', file=sys.stderr)
    print(f'\n{len(problems)} problem(s).\n', file=sys.stderr)
    print('If this is real data, replace it with names from '
          'tools/test-vocabulary.txt.', file=sys.stderr)
    print('If it is invented and the check is simply unaware of it, add it '
          'to that file', file=sys.stderr)
    print('-- that is the point: new test data is declared, not assumed.',
          file=sys.stderr)
    return 1


if __name__ == '__main__':
    sys.exit(main())
