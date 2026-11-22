import sys
sys.path.insert(0, __file__.rsplit('/', 1)[0])
import rbf
def txt(n):
    t = n.get('text'); return t.rstrip(b'\0').decode('latin1') if t is not None else None
def kid(n, name):
    for k in n.get('kids', []):
        if k['name'] == name: return k
def attrs(n): return dict((k, v[1]) for k, v in n.get('attrs', []))
def walk(n, d, maxd):
    nm = kid(n, 'Name')
    shown = False
    if nm is not None and txt(nm):
        lp = kid(n, 'LayoutParams'); st = kid(n, 'Style'); vis = kid(n, 'Visible')
        info = ''
        if lp:
            parts = []
            for c in lp['kids']:
                v = c.get('value'); v = v[1] if v else txt(c)
                if isinstance(v, float): v = '%g' % v
                parts.append('%s=%s' % (c['name'].replace('Margin', 'M').replace('ContentMode', 'CM').replace('Alignment', 'A'), str(v).replace('CONTENT_MODE_', '').replace('HALIGN_', '').replace('VALIGN_', '')))
            info = ' '.join(parts)
        extra = []
        for key in ('RawText', 'Text', 'TextureDictionary', 'Texture', 'TiledTextureId', 'Color', 'SymbolName'):
            k = kid(n, key)
            if k and txt(k): extra.append('%s=%s' % (key, txt(k)[:40]))
        print('  ' * d + txt(nm), attrs(n).get('type', ''), txt(st) if st else '', ('VIS=%s' % vis['value'][1]) if vis and 'value' in vis else '', info, ' '.join(extra))
        shown = True
    if d >= maxd: return
    for c in n.get('kids', []):
        if c['name'] in ('Children', 'Item', 'PrefabObject'):
            walk(c, d + (1 if shown else 0), maxd)
if __name__ == '__main__':
    r = rbf.parse(open(sys.argv[1], 'rb').read())
    walk(r, 0, int(sys.argv[2]) if len(sys.argv) > 2 else 99)
