/// The Wren-side libraries: `studio` (the scene) and `math`. Wren is the secondary
/// language; this API is kept stable and catches up with Luau's on alternate major
/// releases rather than every release.

/// `import "studio" for Workspace, Vec3, ...`
let wrenStudioModuleSource = #"""
class Studio {
  foreign static invoke_(name)
  foreign static invoke_(name, a)
  foreign static invoke_(name, a, b)
  foreign static invoke_(name, a, b, c)
  foreign static invoke_(name, a, b, c, d)
}

class Vec3 {
  construct new(x, y, z) {
    _x = x
    _y = y
    _z = z
  }

  static zero { Vec3.new(0, 0, 0) }
  static one { Vec3.new(1, 1, 1) }
  static up { Vec3.new(0, 1, 0) }
  static fromList_(l) { Vec3.new(l[0], l[1], l[2]) }

  x { _x }
  y { _y }
  z { _z }
  x=(v) { _x = v }
  y=(v) { _y = v }
  z=(v) { _z = v }
  list_ { [_x, _y, _z] }

  +(o) { Vec3.new(_x + o.x, _y + o.y, _z + o.z) }
  -(o) { Vec3.new(_x - o.x, _y - o.y, _z - o.z) }
  *(s) { Vec3.new(_x * s, _y * s, _z * s) }
  /(s) { Vec3.new(_x / s, _y / s, _z / s) }
  ==(o) { o is Vec3 && _x == o.x && _y == o.y && _z == o.z }
  !=(o) { !(this == o) }

  length { (_x * _x + _y * _y + _z * _z).sqrt }
  lengthSquared { _x * _x + _y * _y + _z * _z }
  sum { _x + _y + _z }
  largestComponent {
    var largest = _x
    if (_y > largest) largest = _y
    if (_z > largest) largest = _z
    return largest
  }
  smallestComponent {
    var smallest = _x
    if (_y < smallest) smallest = _y
    if (_z < smallest) smallest = _z
    return smallest
  }

  distanceTo(o) { (this - o).length }
  static distance(a, b) { (a - b).length }

  abs { Vec3.new(_x.abs, _y.abs, _z.abs) }
  floor { Vec3.new(_x.floor, _y.floor, _z.floor) }
  ceil { Vec3.new(_x.ceil, _y.ceil, _z.ceil) }
  round { Vec3.new(_x.round, _y.round, _z.round) }

  withX(v) { Vec3.new(v, _y, _z) }
  withY(v) { Vec3.new(_x, v, _z) }
  withZ(v) { Vec3.new(_x, _y, v) }

  scaled(o) { Vec3.new(_x * o.x, _y * o.y, _z * o.z) }
  min(o) { Vec3.new(_x.min(o.x), _y.min(o.y), _z.min(o.z)) }
  max(o) { Vec3.new(_x.max(o.x), _y.max(o.y), _z.max(o.z)) }

  reflect(normal) {
    var n = normal.normalized
    return this - n * (2 * this.dot(n))
  }

  project(axis) {
    var lengthSquared = axis.lengthSquared
    if (lengthSquared == 0) return Vec3.zero
    return axis * (this.dot(axis) / lengthSquared)
  }

  /// The angle between two directions, in degrees.
  angleTo(o) {
    var denominator = length * o.length
    if (denominator == 0) return 0
    var cosine = (this.dot(o) / denominator)
    if (cosine > 1) cosine = 1
    if (cosine < -1) cosine = -1
    return cosine.acos * 180 / 3.141592653589793
  }

  /// Turned about Y the same way a part's Y rotation turns it: +X towards -Z.
  rotatedY(degrees) {
    var radians = degrees * 3.141592653589793 / 180
    var c = radians.cos
    var s = radians.sin
    return Vec3.new(_x * c + _z * s, _y, _z * c - _x * s)
  }

  static onCircleY(degrees, radius) { Vec3.new(radius, 0, 0).rotatedY(degrees) }

  dot(o) { _x * o.x + _y * o.y + _z * o.z }
  cross(o) {
    return Vec3.new(_y * o.z - _z * o.y, _z * o.x - _x * o.z, _x * o.y - _y * o.x)
  }
  normalized {
    var l = length
    if (l == 0) return Vec3.zero
    return this / l
  }
  lerp(o, t) { this + (o - this) * t }
  toString { "Vec3(%(_x), %(_y), %(_z))" }
}

class Color {
  construct new(r, g, b) {
    _r = r
    _g = g
    _b = b
  }

  static rgb(r, g, b) { Color.new(r / 255, g / 255, b / 255) }
  static gray(v) { Color.new(v, v, v) }

  /// Hue in degrees, saturation and value 0..1.
  static hsv(hue, saturation, value) {
    var h = ((hue % 360) + 360) % 360 / 60
    var c = value * saturation
    var x = c * (1 - ((h % 2) - 1).abs)
    var m = value - c
    var r = 0
    var g = 0
    var b = 0
    if (h < 1) {
      r = c
      g = x
    } else if (h < 2) {
      r = x
      g = c
    } else if (h < 3) {
      g = c
      b = x
    } else if (h < 4) {
      g = x
      b = c
    } else if (h < 5) {
      r = x
      b = c
    } else {
      r = c
      b = x
    }
    return Color.new(r + m, g + m, b + m)
  }

  static fromList_(l) { Color.new(l[0], l[1], l[2]) }
  static red { Color.new(0.91, 0.30, 0.28) }
  static green { Color.new(0.45, 0.78, 0.40) }
  static blue { Color.new(0.30, 0.55, 0.92) }
  static yellow { Color.new(0.95, 0.80, 0.30) }
  static white { Color.new(1, 1, 1) }
  static black { Color.new(0, 0, 0) }

  r { _r }
  g { _g }
  b { _b }
  r=(v) { _r = v }
  g=(v) { _g = v }
  b=(v) { _b = v }
  list_ { [_r, _g, _b] }
  lerp(o, t) { Color.new(_r + (o.r - _r) * t, _g + (o.g - _g) * t, _b + (o.b - _b) * t) }
  darkened(t) { lerp(Color.black, t) }
  lightened(t) { lerp(Color.white, t) }
  luma { _r * 0.2126 + _g * 0.7152 + _b * 0.0722 }
  grayscale { Color.gray(luma) }
  toString { "Color(%(_r), %(_g), %(_b))" }
}

class Part {
  construct new_(id) { _id = id }

  static wrap_(id) {
    if (id == null) return null
    return Part.new_(id)
  }

  id { _id }
  exists { Studio.invoke_("part.exists", _id) }

  name { Studio.invoke_("part.get", _id, "name") }
  name=(v) { Studio.invoke_("part.set", _id, "name", v) }

  shape { Studio.invoke_("part.get", _id, "shape") }
  shape=(v) { Studio.invoke_("part.set", _id, "shape", v) }

  material { Studio.invoke_("part.get", _id, "material") }
  material=(v) { Studio.invoke_("part.set", _id, "material", v) }

  position { Vec3.fromList_(Studio.invoke_("part.get", _id, "position")) }
  position=(v) { Studio.invoke_("part.set", _id, "position", v.list_) }

  size { Vec3.fromList_(Studio.invoke_("part.get", _id, "size")) }
  size=(v) { Studio.invoke_("part.set", _id, "size", v.list_) }

  rotation { Vec3.fromList_(Studio.invoke_("part.get", _id, "rotation")) }
  rotation=(v) { Studio.invoke_("part.set", _id, "rotation", v.list_) }

  color { Color.fromList_(Studio.invoke_("part.get", _id, "color")) }
  color=(v) { Studio.invoke_("part.set", _id, "color", v.list_) }

  transparency { Studio.invoke_("part.get", _id, "transparency") }
  transparency=(v) { Studio.invoke_("part.set", _id, "transparency", v) }

  anchored { Studio.invoke_("part.get", _id, "anchored") }
  anchored=(v) { Studio.invoke_("part.set", _id, "anchored", v) }

  visible { Studio.invoke_("part.get", _id, "visible") }
  visible=(v) { Studio.invoke_("part.set", _id, "visible", v) }

  locked { Studio.invoke_("part.get", _id, "locked") }
  locked=(v) { Studio.invoke_("part.set", _id, "locked", v) }

  shader { Shader.wrap_(Studio.invoke_("part.get", _id, "shader")) }
  shader=(v) {
    if (v == null) {
      Studio.invoke_("part.set", _id, "shader", null)
    } else {
      Studio.invoke_("part.set", _id, "shader", v.id)
    }
  }

  moveBy(v) { position = position + v }
  rotateBy(v) { rotation = rotation + v }
  clone() { Part.wrap_(Studio.invoke_("part.clone", _id)) }
  destroy() { Studio.invoke_("part.destroy", _id) }

  ==(o) { o is Part && o.id == _id }
  !=(o) { !(this == o) }
  toString { "Part(%(name))" }
}

class Workspace {
  static count { Studio.invoke_("workspace.count") }

  static parts {
    var out = []
    for (id in Studio.invoke_("workspace.ids")) {
      out.add(Part.new_(id))
    }
    return out
  }

  static find(name) { Part.wrap_(Studio.invoke_("workspace.find", name)) }

  static findAll(name) {
    var out = []
    for (id in Studio.invoke_("workspace.findAll", name)) {
      out.add(Part.new_(id))
    }
    return out
  }

  static create(shape) { Part.wrap_(Studio.invoke_("workspace.create", shape)) }

  static create(shape, position) {
    var part = create(shape)
    if (part != null) part.position = position
    return part
  }
}

class Shader {
  construct new_(id) { _id = id }

  static wrap_(id) {
    if (id == null) return null
    return Shader.new_(id)
  }

  id { _id }
  name { Studio.invoke_("shader.get", _id, "name") }
  enabled { Studio.invoke_("shader.get", _id, "enabled") }
  enabled=(v) { Studio.invoke_("shader.set", _id, "enabled", v) }
  compiled { Studio.invoke_("shader.get", _id, "compiled") }
  kind { Studio.invoke_("shader.get", _id, "kind") }

  parameters {
    var out = []
    for (name in Studio.invoke_("shader.parameters", _id)) {
      out.add(name)
    }
    return out
  }

  get(name) { Studio.invoke_("shader.param.get", _id, name) }
  set(name, value) { Studio.invoke_("shader.param.set", _id, name, value) }

  applyTo(part) { part.shader = this }

  ==(o) { o is Shader && o.id == _id }
  !=(o) { !(this == o) }
  toString { "Shader(%(name))" }
}

/// The sheet of glass in front of the camera.
class Screen {
  static shader { Shader.wrap_(Studio.invoke_("screen.get")) }

  static shader=(v) {
    if (v == null) {
      Studio.invoke_("screen.set", null)
    } else {
      Studio.invoke_("screen.set", v.id)
    }
  }

  static off() { Studio.invoke_("screen.set", null) }
}

class Shaders {
  static count { Studio.invoke_("shader.count") }

  static all {
    var out = []
    for (id in Studio.invoke_("shader.ids")) {
      out.add(Shader.new_(id))
    }
    return out
  }

  static find(name) { Shader.wrap_(Studio.invoke_("shader.find", name)) }

  static screens {
    var out = []
    for (id in Studio.invoke_("shader.ids", "screen")) {
      out.add(Shader.new_(id))
    }
    return out
  }
}

class Player {
  static position { Vec3.fromList_(Studio.invoke_("player.get", "position")) }
  static velocity { Vec3.fromList_(Studio.invoke_("player.get", "velocity")) }
  static grounded { Studio.invoke_("player.get", "grounded") }
  static speed { Studio.invoke_("player.get", "speed") }
  static teleport(v) { Studio.invoke_("player.set", "position", v.list_) }
}

class Script {
  construct new_(id) { _id = id }
  static forId_(id) { Script.new_(id) }
  id { _id }
  name { Studio.invoke_("script.get", _id, "name") }
  parent { Part.wrap_(Studio.invoke_("script.parent", _id)) }
  toString { "Script(%(name))" }
}

class Runtime {
  static time { Studio.invoke_("runtime.time") }
  static log(message) { Studio.invoke_("runtime.log", message.toString) }

  static onUpdate(fn) {
    if (__updates == null) __updates = []
    __updates.add(fn)
  }

  static reset_() { __updates = [] }

  static tick_(dt) {
    if (__updates == null) return
    for (fn in __updates) {
      fn.call(dt)
    }
  }
}
"""#

/// `import "math" for Math, Ease, Rand, Noise`
let wrenMathModuleSource = #"""
import "studio" for Vec3, Color

class Math {
  static pi { 3.141592653589793 }
  static tau { 6.283185307179586 }
  static e { 2.718281828459045 }
  static epsilon { 0.000001 }

  static clamp(value, low, high) {
    if (value < low) return low
    if (value > high) return high
    return value
  }

  static saturate(value) { clamp(value, 0, 1) }

  static lerp(a, b, t) { a + (b - a) * t }
  static lerpClamped(a, b, t) { lerp(a, b, saturate(t)) }

  static inverseLerp(a, b, value) {
    if ((b - a).abs < epsilon) return 0
    return (value - a) / (b - a)
  }

  static remap(value, fromLow, fromHigh, toLow, toHigh) {
    return lerp(toLow, toHigh, inverseLerp(fromLow, fromHigh, value))
  }

  static remapClamped(value, fromLow, fromHigh, toLow, toHigh) {
    return lerp(toLow, toHigh, saturate(inverseLerp(fromLow, fromHigh, value)))
  }

  static step(edge, value) { value < edge ? 0 : 1 }

  static smoothstep(edge0, edge1, value) {
    var t = saturate(inverseLerp(edge0, edge1, value))
    return t * t * (3 - 2 * t)
  }

  static smootherstep(edge0, edge1, value) {
    var t = saturate(inverseLerp(edge0, edge1, value))
    return t * t * t * (t * (t * 6 - 15) + 10)
  }

  static sign(value) {
    if (value > 0) return 1
    if (value < 0) return -1
    return 0
  }

  static approximately(a, b) { (a - b).abs <= epsilon }
  static approximately(a, b, tolerance) { (a - b).abs <= tolerance }

  static degrees(radians) { radians * 180 / pi }
  static radians(degrees) { degrees * pi / 180 }

  static wrapAngle(degrees) { wrap(degrees + 180, 360) - 180 }
  static deltaAngle(from, to) { wrapAngle(to - from) }

  static moveTowardsAngle(current, target, maxDelta) {
    var delta = deltaAngle(current, target)
    if (delta.abs <= maxDelta) return target
    return current + sign(delta) * maxDelta
  }

  static wrap(value, length) {
    if (length == 0) return 0
    return value - (value / length).floor * length
  }

  static pingPong(value, length) {
    if (length == 0) return 0
    var t = wrap(value, length * 2)
    return length - (t - length).abs
  }

  static moveTowards(current, target, maxDelta) {
    var delta = target - current
    if (delta.abs <= maxDelta) return target
    return current + sign(delta) * maxDelta
  }

  static snap(value, step) {
    if (step <= 0) return value
    return (value / step).round * step
  }

  static minOf(values) {
    if (values.count == 0) return 0
    var result = values[0]
    for (value in values) {
      if (value < result) result = value
    }
    return result
  }

  static maxOf(values) {
    if (values.count == 0) return 0
    var result = values[0]
    for (value in values) {
      if (value > result) result = value
    }
    return result
  }

  static sum(values) {
    var total = 0
    for (value in values) total = total + value
    return total
  }

  static average(values) {
    if (values.count == 0) return 0
    return sum(values) / values.count
  }
}

class Ease {
  static linear(t) { t }

  static inSine(t) { 1 - (t * Math.pi / 2).cos }
  static outSine(t) { (t * Math.pi / 2).sin }
  static inOutSine(t) { -((t * Math.pi).cos - 1) / 2 }

  static inQuad(t) { t * t }
  static outQuad(t) { 1 - (1 - t) * (1 - t) }
  static inOutQuad(t) { t < 0.5 ? 2 * t * t : 1 - (-2 * t + 2).pow(2) / 2 }

  static inCubic(t) { t * t * t }
  static outCubic(t) { 1 - (1 - t).pow(3) }
  static inOutCubic(t) { t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2).pow(3) / 2 }

  static inQuart(t) { t * t * t * t }
  static outQuart(t) { 1 - (1 - t).pow(4) }

  static inExpo(t) { t == 0 ? 0 : (2).pow(10 * t - 10) }
  static outExpo(t) { t == 1 ? 1 : 1 - (2).pow(-10 * t) }

  static inCirc(t) { 1 - (1 - t * t).sqrt }
  static outCirc(t) { (1 - (t - 1) * (t - 1)).sqrt }

  static inBack(t) { 2.70158 * t * t * t - 1.70158 * t * t }
  static outBack(t) {
    var u = t - 1
    return 1 + 2.70158 * u * u * u + 1.70158 * u * u
  }

  static outElastic(t) {
    if (t == 0) return 0
    if (t == 1) return 1
    return (2).pow(-10 * t) * ((t * 10 - 0.75) * (2 * Math.pi / 3)).sin + 1
  }

  static outBounce(t) {
    var n = 7.5625
    var d = 2.75
    if (t < 1 / d) return n * t * t
    if (t < 2 / d) {
      var u = t - 1.5 / d
      return n * u * u + 0.75
    }
    if (t < 2.5 / d) {
      var u = t - 2.25 / d
      return n * u * u + 0.9375
    }
    var u = t - 2.625 / d
    return n * u * u + 0.984375
  }

  static inBounce(t) { 1 - outBounce(1 - t) }
}

class Rand {
  static seed(value) {
    __state = Math.wrap(value.floor.abs, 4294967296)
    if (__state == 0) __state = 1
  }

  static next_ {
    if (__state == null) seed((System.clock * 1000).floor + 12345)
    __state = (1664525 * __state + 1013904223) % 4294967296
    return __state / 4294967296
  }

  static float { next_ }
  static float(high) { next_ * high }
  static float(low, high) { low + next_ * (high - low) }

  static int(high) { (next_ * high).floor }
  static int(low, high) { low + (next_ * (high - low)).floor }

  static bool { next_ < 0.5 }
  static sign { next_ < 0.5 ? -1 : 1 }
  static angle { next_ * 360 }

  static pick(items) {
    if (items.count == 0) return null
    return items[int(items.count)]
  }

  static shuffle(items) {
    var index = items.count - 1
    while (index > 0) {
      var other = int(index + 1)
      var held = items[index]
      items[index] = items[other]
      items[other] = held
      index = index - 1
    }
    return items
  }

  static vec3 { Vec3.new(next_, next_, next_) }
  static vec3(low, high) { Vec3.new(float(low, high), float(low, high), float(low, high)) }

  static direction {
    var z = float(-1, 1)
    var a = float(0, Math.tau)
    var r = (1 - z * z).sqrt
    return Vec3.new(r * a.cos, r * a.sin, z)
  }

  static onSphere(radius) { direction * radius }
  static insideSphere(radius) { direction * (radius * next_.pow(1 / 3)) }

  static color { Color.new(next_, next_, next_) }
}

class Noise {
  static seed(value) { __offset = value * 17.31 }

  static offset_ { __offset == null ? 0 : __offset }

  static hash_(x, y, z) {
    var v = (x * 127.1 + y * 311.7 + z * 74.7 + offset_).sin * 43758.5453123
    return v - v.floor
  }

  static fade_(t) { t * t * (3 - 2 * t) }

  static value(x) { value(x, 0, 0) }
  static value(x, y) { value(x, y, 0) }

  static value(x, y, z) {
    var xi = x.floor
    var yi = y.floor
    var zi = z.floor
    var xf = fade_(x - xi)
    var yf = fade_(y - yi)
    var zf = fade_(z - zi)

    var near = Math.lerp(
      Math.lerp(hash_(xi, yi, zi), hash_(xi + 1, yi, zi), xf),
      Math.lerp(hash_(xi, yi + 1, zi), hash_(xi + 1, yi + 1, zi), xf), yf)
    var far = Math.lerp(
      Math.lerp(hash_(xi, yi, zi + 1), hash_(xi + 1, yi, zi + 1), xf),
      Math.lerp(hash_(xi, yi + 1, zi + 1), hash_(xi + 1, yi + 1, zi + 1), xf), yf)

    return Math.lerp(near, far, zf)
  }

  static fbm(x, y) { fbm(x, y, 4) }

  static fbm(x, y, octaves) {
    var total = 0
    var amplitude = 1
    var frequency = 1
    var weight = 0
    var index = 0
    while (index < octaves) {
      total = total + value(x * frequency, y * frequency) * amplitude
      weight = weight + amplitude
      amplitude = amplitude * 0.5
      frequency = frequency * 2
      index = index + 1
    }
    if (weight == 0) return 0
    return total / weight
  }
}
"""#
