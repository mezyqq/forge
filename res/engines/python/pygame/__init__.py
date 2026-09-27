# pygame для Forge: основная часть API pygame поверх встроенной графики Forge (_gfx).
# Окно рисуется над консолью; касания — мышь, экранный пульт — стрелки, пробел, Enter, Esc.
# Рисовать можно только на экран (display.set_mode); Surface((w, h)) + fill() рисуется как залитый прямоугольник.
import _gfx

# типы событий и клавиши (значения как в pygame 2)
QUIT = 256
KEYDOWN = 768
KEYUP = 769
MOUSEMOTION = 1024
MOUSEBUTTONDOWN = 1025
MOUSEBUTTONUP = 1026
K_LEFT = 1073741904
K_RIGHT = 1073741903
K_UP = 1073741906
K_DOWN = 1073741905
K_SPACE = 32
K_RETURN = 13
K_ESCAPE = 27
K_a = 97
K_d = 100
K_s = 115
K_w = 119
SRCALPHA = 65536
FULLSCREEN = 1
RESIZABLE = 16

# кнопки пульта Forge → клавиши pygame (стрелки заодно нажимают WASD)
_KEYS = {1: [K_LEFT, K_a], 2: [K_RIGHT, K_d], 3: [K_UP, K_w], 4: [K_DOWN, K_s], 5: [K_SPACE], 6: [K_RETURN], 7: [K_ESCAPE]}
_pressed = set()
_mouse = [0, 0]
_buttons = [False, False, False]
_screen = None

_NAMED = {
    'black': (0, 0, 0), 'white': (255, 255, 255), 'red': (255, 0, 0), 'green': (0, 255, 0),
    'blue': (0, 0, 255), 'yellow': (255, 255, 0), 'cyan': (0, 255, 255), 'magenta': (255, 0, 255),
    'gray': (128, 128, 128), 'grey': (128, 128, 128), 'orange': (255, 165, 0), 'purple': (128, 0, 128),
    'pink': (255, 192, 203), 'brown': (139, 69, 19), 'darkgray': (64, 64, 64), 'lightgray': (211, 211, 211),
}


def _rgba(c):
    if isinstance(c, str):
        c = _NAMED.get(c.lower().replace(' ', ''), (255, 255, 255))
    if isinstance(c, Color):
        return (c.r, c.g, c.b, c.a)
    return (c[0], c[1], c[2], c[3] if len(c) > 3 else 255)


def _use(c):
    r, g, b, a = _rgba(c)
    _gfx.color(r, g, b, a)


def init():
    return (6, 0)


def quit():
    pass


def get_init():
    return True


class error(Exception):
    pass


class Color:
    def __init__(self, r, g=None, b=None, a=255):
        if g is None:
            r, g, b, a = _rgba(r)
        self.r, self.g, self.b, self.a = int(r), int(g), int(b), int(a)

    def __getitem__(self, i):
        return (self.r, self.g, self.b, self.a)[i]

    def __len__(self):
        return 4

    def __iter__(self):
        return iter((self.r, self.g, self.b, self.a))


class Rect:
    def __init__(self, *args):
        if len(args) == 1:
            args = tuple(args[0])
        if len(args) == 2:
            (x, y), (w, h) = args
        else:
            x, y, w, h = args
        self.x, self.y, self.w, self.h = x, y, w, h

    # pocketpy: свойства через property()
    def _gl(self): return self.x
    def _sl(self, v): self.x = v
    left = property(_gl, _sl)
    def _gt(self): return self.y
    def _st(self, v): self.y = v
    top = property(_gt, _st)
    def _gr(self): return self.x + self.w
    def _sr(self, v): self.x = v - self.w
    right = property(_gr, _sr)
    def _gb(self): return self.y + self.h
    def _sb(self, v): self.y = v - self.h
    bottom = property(_gb, _sb)
    def _gw(self): return self.w
    def _sw(self, v): self.w = v
    width = property(_gw, _sw)
    def _gh(self): return self.h
    def _sh(self, v): self.h = v
    height = property(_gh, _sh)
    def _gcx(self): return self.x + self.w // 2
    def _scx(self, v): self.x = v - self.w // 2
    centerx = property(_gcx, _scx)
    def _gcy(self): return self.y + self.h // 2
    def _scy(self, v): self.y = v - self.h // 2
    centery = property(_gcy, _scy)
    def _gc(self): return (self.centerx, self.centery)
    def _sc(self, v): self.centerx, self.centery = v[0], v[1]
    center = property(_gc, _sc)
    def _gtl(self): return (self.x, self.y)
    def _stl(self, v): self.x, self.y = v[0], v[1]
    topleft = property(_gtl, _stl)
    def _gsz(self): return (self.w, self.h)
    def _ssz(self, v): self.w, self.h = v[0], v[1]
    size = property(_gsz, _ssz)

    def __getitem__(self, i):
        return (self.x, self.y, self.w, self.h)[i]

    def __len__(self):
        return 4

    def __iter__(self):
        return iter((self.x, self.y, self.w, self.h))

    def __repr__(self):
        return '<rect(%d, %d, %d, %d)>' % (self.x, self.y, self.w, self.h)

    def copy(self):
        return Rect(self.x, self.y, self.w, self.h)

    def move(self, dx, dy=None):
        if dy is None:
            dx, dy = dx
        return Rect(self.x + dx, self.y + dy, self.w, self.h)

    def move_ip(self, dx, dy=None):
        if dy is None:
            dx, dy = dx
        self.x += dx
        self.y += dy

    def inflate(self, dx, dy):
        return Rect(self.x - dx // 2, self.y - dy // 2, self.w + dx, self.h + dy)

    def clamp_ip(self, other):
        o = Rect(other)
        self.x = max(o.x, min(self.x, o.right - self.w))
        self.y = max(o.y, min(self.y, o.bottom - self.h))

    def colliderect(self, other):
        o = Rect(other)
        return self.x < o.x + o.w and o.x < self.x + self.w and self.y < o.y + o.h and o.y < self.y + self.h

    def collidepoint(self, x, y=None):
        if y is None:
            x, y = x
        return self.x <= x < self.x + self.w and self.y <= y < self.y + self.h

    def collidelist(self, rects):
        for i, r in enumerate(rects):
            if self.colliderect(r):
                return i
        return -1


def _rect(r):
    return r if isinstance(r, Rect) else Rect(r)


class Surface:
    """Экран или «плоская» поверхность: fill() запоминает цвет, blit рисует её прямоугольником."""

    def __init__(self, size, flags=0, depth=0, masks=None):
        self._w, self._h = int(size[0]), int(size[1])
        self._is_screen = False
        self._fill = None
        self._alpha = 255

    def get_width(self):
        return self._w

    def get_height(self):
        return self._h

    def get_size(self):
        return (self._w, self._h)

    def get_rect(self, **kw):
        r = Rect(0, 0, self._w, self._h)
        for k in kw:
            setattr(r, k, kw[k])
        return r

    def fill(self, color, rect=None, special_flags=0):
        if not self._is_screen:
            self._fill = _rgba(color)
            return
        _use(color)
        if rect is None:
            _gfx.rect(0, 0, self._w, self._h, 0)
        else:
            r = _rect(rect)
            _gfx.rect(r.x, r.y, r.w, r.h, 0)

    def blit(self, src, dest, area=None, special_flags=0):
        if not self._is_screen:
            return None
        if isinstance(dest, Rect):
            x, y = dest.x, dest.y
        else:
            x, y = dest[0], dest[1]
        src._draw_at(x, y)
        return Rect(x, y, src._w, src._h)

    def blits(self, pairs, *args):
        for p in pairs:
            self.blit(p[0], p[1])

    def _draw_at(self, x, y):
        if self._fill is not None:
            r, g, b, a = self._fill
            _gfx.color(r, g, b, a * self._alpha // 255)
            _gfx.rect(x, y, self._w, self._h, 0)

    def convert(self, *args):
        return self

    def convert_alpha(self, *args):
        return self

    def set_colorkey(self, *args):
        pass

    def set_alpha(self, a, *args):
        self._alpha = 255 if a is None else int(a)

    def copy(self):
        s = Surface((self._w, self._h))
        s._fill = self._fill
        return s


class _Image(Surface):
    def __init__(self, handle, w=None, h=None):
        self._handle = handle
        Surface.__init__(self, (w if w is not None else _gfx.image_w(handle), h if h is not None else _gfx.image_h(handle)))

    def _draw_at(self, x, y):
        _gfx.image_draw(self._handle, x, y, self._w, self._h)

    def copy(self):
        return _Image(self._handle, self._w, self._h)


class _Text(Surface):
    def __init__(self, text, size, color):
        self._text, self._size, self._color = text, size, _rgba(color)
        Surface.__init__(self, (int(_gfx.measure(text, size)) + 1, int(size * 1.25)))

    def _draw_at(self, x, y):
        r, g, b, a = self._color
        _gfx.color(r, g, b, a)
        _gfx.text(self._text, x, y, self._size)


class _Display:
    def set_mode(self, size=(0, 0), flags=0, depth=0, display=0, vsync=0):
        global _screen
        w, h = int(size[0]) or 800, int(size[1]) or 600
        _gfx.open(w, h)
        s = Surface((w, h))
        s._is_screen = True
        _screen = s
        return s

    def get_surface(self):
        return _screen

    def set_caption(self, *args):
        pass

    def set_icon(self, *args):
        pass

    def flip(self):
        _gfx.present()

    def update(self, *args):
        _gfx.present()

    def get_init(self):
        return True

    def init(self):
        pass

    def quit(self):
        pass


display = _Display()


class Event:
    def __init__(self, type, **kw):
        self.type = type
        for k in kw:
            setattr(self, k, kw[k])
        self.dict = kw


def _translate(e):
    t, x, y, k = e[0], e[1], e[2], e[3]
    pos = (int(x), int(y))
    if t == 1:
        rel = (pos[0] - _mouse[0], pos[1] - _mouse[1])
        _mouse[0], _mouse[1] = pos
        _buttons[0] = True
        return [Event(MOUSEMOTION, pos=pos, rel=rel, buttons=(1, 0, 0)), Event(MOUSEBUTTONDOWN, pos=pos, button=1)]
    if t == 2:
        _mouse[0], _mouse[1] = pos
        _buttons[0] = False
        return [Event(MOUSEBUTTONUP, pos=pos, button=1)]
    if t == 3:
        rel = (pos[0] - _mouse[0], pos[1] - _mouse[1])
        _mouse[0], _mouse[1] = pos
        return [Event(MOUSEMOTION, pos=pos, rel=rel, buttons=(1 if _buttons[0] else 0, 0, 0))]
    if t == 4 or t == 5:
        out = []
        for key in _KEYS.get(k, []):
            if t == 4:
                _pressed.add(key)
            elif key in _pressed:
                _pressed.remove(key)
            out.append(Event(KEYDOWN if t == 4 else KEYUP, key=key, unicode='', mod=0, scancode=0))
        return out
    if t == 6:
        return [Event(QUIT)]
    return []


class _EventModule:
    def get(self, *args, **kw):
        out = []
        while True:
            e = _gfx.poll()
            if e is None:
                break
            out.extend(_translate(e))
            if e[0] == 6:
                break
        return out

    def poll(self):
        e = _gfx.poll()
        if e is None:
            return Event(0)
        evs = _translate(e)
        return evs[0] if evs else Event(0)

    def pump(self):
        pass

    def wait(self):
        while True:
            evs = self.get()
            if evs:
                return evs[0]
            _gfx.sleep(10)

    def clear(self, *args):
        self.get()

    def set_grab(self, *args):
        pass


event = _EventModule()


class _Pressed:
    def __getitem__(self, k):
        return k in _pressed


class _Key:
    def get_pressed(self):
        return _Pressed()

    def set_repeat(self, *args):
        pass

    def name(self, k):
        return str(k)


key = _Key()


class _Mouse:
    def get_pos(self):
        return (_mouse[0], _mouse[1])

    def get_pressed(self, *args):
        return (_buttons[0], False, False)

    def set_visible(self, *args):
        pass


mouse = _Mouse()


class _Draw:
    def rect(self, surface, color, rect, width=0, border_radius=0, border_top_left_radius=-1, border_top_right_radius=-1, border_bottom_left_radius=-1, border_bottom_right_radius=-1):
        r = _rect(rect)
        if surface is not _screen and surface is not None and not getattr(surface, '_is_screen', False):
            return r
        _use(color)
        _gfx.rect(r.x, r.y, r.w, r.h, width)
        return r

    def circle(self, surface, color, center, radius, width=0, draw_top_right=None, draw_top_left=None, draw_bottom_left=None, draw_bottom_right=None):
        _use(color)
        _gfx.ellipse(center[0] - radius, center[1] - radius, radius * 2, radius * 2, width)
        return Rect(center[0] - radius, center[1] - radius, radius * 2, radius * 2)

    def ellipse(self, surface, color, rect, width=0):
        r = _rect(rect)
        _use(color)
        _gfx.ellipse(r.x, r.y, r.w, r.h, width)
        return r

    def line(self, surface, color, start, end, width=1):
        _use(color)
        _gfx.line(start[0], start[1], end[0], end[1], width)

    def lines(self, surface, color, closed, points, width=1):
        _use(color)
        for i in range(len(points) - 1):
            _gfx.line(points[i][0], points[i][1], points[i + 1][0], points[i + 1][1], width)
        if closed and len(points) > 2:
            _gfx.line(points[-1][0], points[-1][1], points[0][0], points[0][1], width)

    def aaline(self, surface, color, start, end, *args):
        self.line(surface, color, start, end, 1)

    def polygon(self, surface, color, points, width=0):
        _use(color)
        flat = []
        for p in points:
            flat.append(p[0])
            flat.append(p[1])
        _gfx.poly(flat, width)


draw = _Draw()


class _Clock:
    def __init__(self):
        self._last = _gfx.ticks()
        self._fps = 0.0

    def tick(self, framerate=0):
        now = _gfx.ticks()
        if framerate:
            wait = 1000.0 / framerate - (now - self._last)
            if wait > 0:
                _gfx.sleep(wait)
                now = _gfx.ticks()
        dt = now - self._last
        self._last = now
        if dt > 0:
            self._fps = 1000.0 / dt
        return int(dt)

    def get_fps(self):
        return self._fps

    def get_time(self):
        return 0


class _Time:
    def Clock(self):
        return _Clock()

    def get_ticks(self):
        return int(_gfx.ticks())

    def delay(self, ms):
        _gfx.sleep(ms)
        return ms

    def wait(self, ms):
        _gfx.sleep(ms)
        return ms

    def set_timer(self, *args):
        pass


time = _Time()


class _Font:
    def __init__(self, name=None, size=24, bold=False, italic=False):
        self._size = size * 0.75  # размер pygame — высота строки, у нас — кегль

    def render(self, text, antialias=True, color=(255, 255, 255), background=None):
        return _Text(str(text), self._size, color)

    def size(self, text):
        return (int(_gfx.measure(str(text), self._size)) + 1, int(self._size * 1.25))

    def get_height(self):
        return int(self._size * 1.25)

    def get_linesize(self):
        return int(self._size * 1.3)

    def set_bold(self, *args):
        pass


class _FontModule:
    def init(self):
        pass

    def get_init(self):
        return True

    def Font(self, name=None, size=24):
        return _Font(name, size)

    def SysFont(self, name, size, bold=False, italic=False):
        return _Font(name, size)

    def get_fonts(self):
        return ['system']

    def quit(self):
        pass


font = _FontModule()


class _ImageModule:
    def load(self, path, *args):
        h = _gfx.image_load(str(path))
        if h < 0:
            raise error('cannot load image: ' + str(path))
        return _Image(h)


image = _ImageModule()


class _Transform:
    def scale(self, surf, size, *args):
        if isinstance(surf, _Image):
            return _Image(surf._handle, int(size[0]), int(size[1]))
        s = surf.copy()
        s._w, s._h = int(size[0]), int(size[1])
        return s

    def smoothscale(self, surf, size, *args):
        return self.scale(surf, size)

    def rotate(self, surf, angle):
        return surf

    def flip(self, surf, xbool, ybool):
        return surf


transform = _Transform()


class _Sound:
    def __init__(self, *args, **kw):
        pass

    def play(self, *args, **kw):
        pass

    def stop(self):
        pass

    def set_volume(self, *args):
        pass

    def get_length(self):
        return 0.0


class _Music:
    def load(self, *args):
        pass

    def play(self, *args, **kw):
        pass

    def stop(self):
        pass

    def pause(self):
        pass

    def unpause(self):
        pass

    def set_volume(self, *args):
        pass


class _Mixer:
    # звука пока нет: вызовы ничего не делают, чтобы игры не падали
    Sound = _Sound
    music = _Music()

    def init(self, *args, **kw):
        pass

    def pre_init(self, *args, **kw):
        pass

    def quit(self):
        pass


mixer = _Mixer()


class _Sprite:
    def __init__(self, *groups):
        self._groups = []
        for g in groups:
            g.add(self)

    def update(self, *args, **kw):
        pass

    def kill(self):
        for g in list(self._groups):
            g.remove(self)

    def alive(self):
        return len(self._groups) > 0

    def add(self, *groups):
        for g in groups:
            g.add(self)

    def remove(self, *groups):
        for g in groups:
            g.remove(self)

    def groups(self):
        return list(self._groups)


class _Group:
    def __init__(self, *sprites):
        self._sprites = []
        for s in sprites:
            self.add(s)

    def add(self, *sprites):
        for s in sprites:
            if isinstance(s, (list, tuple)):
                self.add(*s)
            elif s not in self._sprites:
                self._sprites.append(s)
                s._groups.append(self)

    def remove(self, *sprites):
        for s in sprites:
            if s in self._sprites:
                self._sprites.remove(s)
                if self in s._groups:
                    s._groups.remove(self)

    def has(self, s):
        return s in self._sprites

    def sprites(self):
        return list(self._sprites)

    def update(self, *args, **kw):
        for s in list(self._sprites):
            s.update(*args, **kw)

    def draw(self, surface, *args):
        for s in self._sprites:
            surface.blit(s.image, s.rect)

    def empty(self):
        for s in list(self._sprites):
            self.remove(s)

    def __len__(self):
        return len(self._sprites)

    def __iter__(self):
        return iter(list(self._sprites))

    def __contains__(self, s):
        return s in self._sprites


def _collide(a, b):
    return a.rect.colliderect(b.rect)


class _SpriteModule:
    Sprite = _Sprite
    Group = _Group
    RenderPlain = _Group
    RenderUpdates = _Group

    def spritecollide(self, sprite, group, dokill, collided=None):
        hit = [s for s in group.sprites() if (collided or _collide)(sprite, s)]
        if dokill:
            for s in hit:
                s.kill()
        return hit

    def spritecollideany(self, sprite, group, collided=None):
        for s in group.sprites():
            if (collided or _collide)(sprite, s):
                return s
        return None

    def groupcollide(self, g1, g2, dokill1, dokill2, collided=None):
        out = {}
        for a in g1.sprites():
            hit = self.spritecollide(a, g2, dokill2, collided)
            if hit:
                out[a] = hit
                if dokill1:
                    a.kill()
        return out

    def collide_rect(self, a, b):
        return _collide(a, b)


sprite = _SpriteModule()


class _Vector2:
    def __init__(self, x=0, y=0):
        if not isinstance(x, (int, float)):
            x, y = x[0], x[1]
        self.x, self.y = x, y

    def __add__(self, o):
        return _Vector2(self.x + o[0], self.y + o[1])

    def __sub__(self, o):
        return _Vector2(self.x - o[0], self.y - o[1])

    def __mul__(self, k):
        return _Vector2(self.x * k, self.y * k)

    def __getitem__(self, i):
        return (self.x, self.y)[i]

    def __len__(self):
        return 2

    def __iter__(self):
        return iter((self.x, self.y))

    def length(self):
        return (self.x * self.x + self.y * self.y) ** 0.5

    def normalize(self):
        n = self.length()
        return _Vector2(self.x / n, self.y / n) if n else _Vector2(0, 0)


class _Math:
    Vector2 = _Vector2


math = _Math()
