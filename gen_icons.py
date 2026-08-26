# 零依赖生成 PWA 图标（纯标准库，不需要 Pillow）
# 生成纯色 PNG 占位图标，颜色可改下面的 RGB
import zlib, struct, os

RGB = (55, 138, 221)  # 图标底色 #378add

def make_png(path, size):
    w = h = size
    raw = b''
    for _ in range(h):
        raw += b'\x00'  # 每行前缀 filter type 0
        for _ in range(w):
            raw += bytes(RGB)
    def chunk(typ, data):
        body = typ + data
        return struct.pack('>I', len(data)) + body + struct.pack('>I', zlib.crc32(body) & 0xffffffff)
    sig = b'\x89PNG\r\n\x1a\n'
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)  # 8-bit, RGB
    idat = zlib.compress(raw, 9)
    png = sig + chunk(b'IHDR', ihdr) + chunk(b'IDAT', idat) + chunk(b'IEND', b'')
    with open(path, 'wb') as f:
        f.write(png)
    print('生成', path, size, 'x', size)

for size, name in [(192, 'icon-192.png'), (512, 'icon-512.png'), (180, 'icon-180.png')]:
    make_png(os.path.join(os.path.dirname(__file__), name), size)
