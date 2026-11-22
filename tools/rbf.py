import struct, sys
from xml.sax.saxutils import escape, quoteattr

def parse(b):
    assert b[:4] == b'RBF0'
    p = 4
    names = []
    types = []
    root = None
    stack = []
    cur = None
    pending = 0
    def elem_value(t):
        nonlocal p
        if t == 0x10:
            v = struct.unpack_from('<q', b, p)[0]; p += 8; return ('i', v)
        if t == 0x20: return ('bool', True)
        if t == 0x30: return ('bool', False)
        if t == 0x40:
            v = struct.unpack_from('<d', b, p)[0]; p += 8; return ('f', v)
        if t == 0x50:
            v = struct.unpack_from('<3f', b, p); p += 12; return ('v3', v)
        if t == 0x60:
            n = struct.unpack_from('<H', b, p)[0]; p += 2
            v = b[p:p+n].decode('latin1'); p += n; return ('s', v)
        raise ValueError('type %x at %x' % (t, p))
    while p < len(b):
        d = b[p]; p += 1
        if d == 0xFF:
            assert b[p] == 0xFF, hex(p); p += 1
            if stack: cur = stack.pop()
            continue
        if d == 0xFD:
            assert b[p] == 0xFF, hex(p); p += 1
            n = struct.unpack_from('<I', b, p)[0]; p += 4
            cur['text'] = b[p:p+n]; p += n
            continue
        if d == 0xFB:
            assert b[p] == 0xFF; p += 1
            ver = struct.unpack_from('<H', b, p)[0]; p += 2
            continue
        t = b[p]; p += 1
        if d == len(names):
            n = struct.unpack_from('<H', b, p)[0]; p += 2
            names.append(b[p:p+n].decode('latin1')); p += n
        elif d > len(names):
            raise ValueError('desc %d > %d at %x' % (d, len(names), p))
        name = names[d]
        if t == 0:
            x = struct.unpack_from('<3H', b, p); p += 6
            node = {'name': name, 'attrs': [], 'kids': [], 'x': x}
            if cur is not None:
                cur['kids'].append(node); stack.append(cur)
            else:
                root = node
            cur = node
            pending = x[2]
        else:
            v = elem_value(t)
            if pending > 0:
                cur['attrs'].append((name, v)); pending -= 1
            else:
                cur['kids'].append({'name': name, 'value': v})
    return root

def fmt(v):
    k, x = v
    if k == 'f': return repr(round(x, 6))
    if k == 'v3': return ','.join(repr(round(a, 6)) for a in x)
    if k == 'bool': return 'true' if x else 'false'
    return str(x)

def toxml(n, ind=0, out=None):
    sp = '  ' * ind
    if 'value' in n:
        out.append('%s<%s value=%s/>' % (sp, n['name'], quoteattr(fmt(n['value']))))
        return
    a = ''.join(' %s=%s' % (k, quoteattr(fmt(v))) for k, v in n['attrs'])
    txt = n.get('text')
    if not n['kids'] and txt is None:
        out.append('%s<%s%s/>' % (sp, n['name'], a)); return
    if not n['kids']:
        s = txt.rstrip(b'\0').decode('utf-8', 'replace')
        out.append('%s<%s%s>%s</%s>' % (sp, n['name'], a, escape(s), n['name'])); return
    out.append('%s<%s%s>' % (sp, n['name'], a))
    if txt is not None:
        out.append('%s  %s' % (sp, escape(txt.rstrip(b'\0').decode('utf-8', 'replace'))))
    for k in n['kids']: toxml(k, ind + 1, out)
    out.append('%s</%s>' % (sp, n['name']))

if __name__ == '__main__':
    import os
    src, dst = sys.argv[1], sys.argv[2]
    os.makedirs(dst, exist_ok=True)
    ok = bad = 0
    for f in sorted(os.listdir(src)):
        b = open(os.path.join(src, f), 'rb').read()
        try:
            r = parse(b)
            out = []
            toxml(r, 0, out)
            ident = ''
            for k in r['kids']:
                if k['name'] in ('Id', 'ID', 'Name') and 'text' in k:
                    ident = k['text'].rstrip(b'\0').decode('latin1'); break
            nm = (ident.replace('/', '__') if ident else r['name'] + '_' + f[:-4]) + '.xml'
            open(os.path.join(dst, nm), 'w').write('\n'.join(out) + '\n')
            ok += 1
        except Exception as e:
            bad += 1
            print(f, e)
    print('ok', ok, 'bad', bad)
