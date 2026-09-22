' A port of the vmath raytracer benchmark, itself based on
' https://github.com/edin/raytracer, to Bassy's BASIC.
'
' Three differences follow from the language rather than the algorithm.
' Numbers are Q16.16 fixed point, so "far away" is 20000 rather than a
' million and the light falloff is coarser. There are no records, so the
' scene lives in parallel arrays. Subroutines cannot return values and
' every scalar that is not a parameter is global, so anything that must
' survive a recursive call is passed as an argument.

dim thingKind(3)
dim thingSurface(3)
dim thingAx(3)
dim thingAy(3)
dim thingAz(3)
dim thingExtra(3)

dim lightX(4)
dim lightY(4)
dim lightZ(4)
dim lightR(4)
dim lightG(4)
dim lightB(4)

' Surfaces
shiny = 0
checkerboard = 1

' Shapes
planeKind = 0
sphereKind = 1

farAway = 200
maxDepth = 3
thingCount = 3
lightCount = 4

sub setPlane(slot, nx, ny, nz, offset, surface)
  thingKind(slot) = planeKind
  thingSurface(slot) = surface
  thingAx(slot) = nx
  thingAy(slot) = ny
  thingAz(slot) = nz
  thingExtra(slot) = offset
end sub

sub setSphere(slot, cx, cy, cz, radius, surface)
  thingKind(slot) = sphereKind
  thingSurface(slot) = surface
  thingAx(slot) = cx
  thingAy(slot) = cy
  thingAz(slot) = cz
  thingExtra(slot) = radius * radius
end sub

sub setLight(slot, lx, ly, lz, r, g, b)
  lightX(slot) = lx
  lightY(slot) = ly
  lightZ(slot) = lz
  lightR(slot) = r
  lightG(slot) = g
  lightB(slot) = b
end sub

' Writes a unit vector into normX, normY, normZ.
sub normalize(vx, vy, vz)
  mag = sqr(vx * vx + vy * vy + vz * vz)
  if mag = 0 then
    normX = 0
    normY = 0
    normZ = 0
    exit sub
  end if
  normX = vx / mag
  normY = vy / mag
  normZ = vz / mag
end sub

' Writes the surface normal at a point into normX, normY, normZ.
sub surfaceNormal(thing, px, py, pz)
  if thingKind(thing) = sphereKind then
    normalize(px - thingAx(thing), py - thingAy(thing), pz - thingAz(thing))
  else
    normX = thingAx(thing)
    normY = thingAy(thing)
    normZ = thingAz(thing)
  end if
end sub

' Writes the nearest hit into hitThing and hitDist. A hitThing of -1 means
' the ray escaped.
sub intersections(sx, sy, sz, dx, dy, dz)
  hitThing = -1
  hitDist = farAway
  probe = 0
  while probe < thingCount
    candidate = -1
    candidateDist = 0
    if thingKind(probe) = sphereKind then
      eox = thingAx(probe) - sx
      eoy = thingAy(probe) - sy
      eoz = thingAz(probe) - sz
      v = eox * dx + eoy * dy + eoz * dz
      if v >= 0 then
        disc = thingExtra(probe) - (eox * eox + eoy * eoy + eoz * eoz - v * v)
        if disc >= 0 then
          candidateDist = v - sqr(disc)
          if candidateDist <> 0 then
            candidate = probe
          end if
        end if
      end if
    else
      denom = thingAx(probe) * dx + thingAy(probe) * dy + thingAz(probe) * dz
      if denom < 0 then
        candidateDist = (thingAx(probe) * sx + thingAy(probe) * sy + thingAz(probe) * sz + thingExtra(probe)) / (0 - denom)
        candidate = probe
      end if
    end if
    if candidate >= 0 then
      if candidateDist < hitDist then
        hitThing = candidate
        hitDist = candidateDist
      end if
    end if
    probe = probe + 1
  wend
end sub

' Writes the surface description at a point into diffuseR/G/B,
' specularR/G/B, reflectance and roughness.
sub surfaceAt(thing, px, py, pz)
  if thingSurface(thing) = shiny then
    diffuseR = 1
    diffuseG = 1
    diffuseB = 1
    specularR = 0.5
    specularG = 0.5
    specularB = 0.5
    reflectance = 0.7
    roughness = 6
  else
    squares = floorOf(pz) + floorOf(px)
    if squares mod 2 <> 0 then
      reflectance = 0.1
      diffuseR = 1
      diffuseG = 1
      diffuseB = 1
    else
      reflectance = 0.7
      diffuseR = 0
      diffuseG = 0
      diffuseB = 0
    end if
    specularR = 1
    specularG = 1
    specularB = 1
    roughness = 5
  end if
end sub

' Adds one light's contribution to lightSumR/G/B.
sub applyLight(slot, px, py, pz, nx, ny, nz, dx, dy, dz, shineR, shineG, shineB, gloss, power)
  ldx = lightX(slot) - px
  ldy = lightY(slot) - py
  ldz = lightZ(slot) - pz
  normalize(ldx, ldy, ldz)
  livx = normX
  livy = normY
  livz = normZ
  intersections(px, py, pz, livx, livy, livz)
  if hitThing >= 0 then
    if hitDist <= sqr(ldx * ldx + ldy * ldy + ldz * ldz) then
      exit sub
    end if
  end if
  illum = livx * nx + livy * ny + livz * nz
  if illum > 0 then
    lightSumR = lightSumR + illum * lightR(slot) * shineR
    lightSumG = lightSumG + illum * lightG(slot) * shineG
    lightSumB = lightSumB + illum * lightB(slot) * shineB
  end if
  specular = livx * dx + livy * dy + livz * dz
  if specular > 0 then
    falloff = specular
    turn = 1
    while turn < power
      falloff = falloff * specular
      turn = turn + 1
    wend
    lightSumR = lightSumR + falloff * lightR(slot) * gloss
    lightSumG = lightSumG + falloff * lightG(slot) * gloss
    lightSumB = lightSumB + falloff * lightB(slot) * gloss
  end if
end sub

sub traceRay(sx, sy, sz, dx, dy, dz, depth)
  intersections(sx, sy, sz, dx, dy, dz)
  if hitThing < 0 then
    colorR = 0
    colorG = 0
    colorB = 0
    exit sub
  end if
  shade(hitThing, hitDist, sx, sy, sz, dx, dy, dz, depth)
end sub

' Combines the already-computed natural colour with a reflected ray. Every
' value it needs is a parameter, because the recursive call below will
' overwrite the globals the caller was using.
sub addReflection(naturalR, naturalG, naturalB, weight, px, py, pz, rdx, rdy, rdz, depth)
  traceRay(px + rdx * 0.002, py + rdy * 0.002, pz + rdz * 0.002, rdx, rdy, rdz, depth + 1)
  colorR = naturalR + colorR * weight
  colorG = naturalG + colorG * weight
  colorB = naturalB + colorB * weight
end sub

sub shade(thing, dist, sx, sy, sz, dx, dy, dz, depth)
  px = sx + dx * dist
  py = sy + dy * dist
  pz = sz + dz * dist
  surfaceNormal(thing, px, py, pz)
  nx = normX
  ny = normY
  nz = normZ
  reflectDot = nx * dx + ny * dy + nz * dz
  rdx = dx - 2 * reflectDot * nx
  rdy = dy - 2 * reflectDot * ny
  rdz = dz - 2 * reflectDot * nz
  surfaceAt(thing, px, py, pz)
  keepDiffuseR = diffuseR
  keepDiffuseG = diffuseG
  keepDiffuseB = diffuseB
  keepSpecular = specularR
  keepReflect = reflectance
  keepRoughness = roughness

  lightSumR = 0
  lightSumG = 0
  lightSumB = 0
  slot = 0
  while slot < lightCount
    applyLight(slot, px, py, pz, nx, ny, nz, rdx, rdy, rdz, keepDiffuseR, keepDiffuseG, keepDiffuseB, keepSpecular, keepRoughness)
    slot = slot + 1
  wend

  if depth >= maxDepth then
    colorR = lightSumR + 0.5
    colorG = lightSumG + 0.5
    colorB = lightSumB + 0.5
    exit sub
  end if
  addReflection(lightSumR, lightSumG, lightSumB, keepReflect, px, py, pz, rdx, rdy, rdz, depth)
end sub

' Scene
setPlane(0, 0, 1, 0, 0, checkerboard)
setSphere(1, 0, 1, -0.25, 1, shiny)
setSphere(2, -1, 0.5, 1.5, 0.5, shiny)
setLight(0, -2, 2.5, 0, 0.49, 0.07, 0.07)
setLight(1, 1.5, 2.5, 1.5, 0.07, 0.07, 0.49)
setLight(2, 1.5, 2.5, -1.5, 0.07, 0.49, 0.071)
setLight(3, 0, 3.5, 0, 0.21, 0.21, 0.35)

' Camera at (3, 2, 4) looking at (-1, 0.5, 0)
normalize(-4, -1.5, -4)
forwardX = normX
forwardY = normY
forwardZ = normZ
' right = forward cross down, with down = (0, -1, 0)
rightRawX = forwardY * 0 - forwardZ * -1
rightRawY = forwardZ * 0 - forwardX * 0
rightRawZ = forwardX * -1 - forwardY * 0
normalize(rightRawX, rightRawY, rightRawZ)
rightX = normX * 1.5
rightY = normY * 1.5
rightZ = normZ * 1.5
upRawX = forwardY * rightRawZ - forwardZ * rightRawY
upRawY = forwardZ * rightRawX - forwardX * rightRawZ
upRawZ = forwardX * rightRawY - forwardY * rightRawX
normalize(upRawX, upRawY, upRawZ)
upX = normX * 1.5
upY = normY * 1.5
upZ = normZ * 1.5

checksum = 0
py2 = 0
while py2 < size
  px2 = 0
  while px2 < size
    recenterX = (px2 - half) / half
    recenterY = (half - py2) / half
    rayX = forwardX + recenterX * rightX + recenterY * upX
    rayY = forwardY + recenterX * rightY + recenterY * upY
    rayZ = forwardZ + recenterX * rightZ + recenterY * upZ
    normalize(rayX, rayY, rayZ)
    traceRay(3, 2, 4, normX, normY, normZ, 0)
    red = clampByte(colorR)
    green = clampByte(colorG)
    blue = clampByte(colorB)
    checksum = checksum + red + green * 3 + blue * 7
    plot(red, green, blue)
    px2 = px2 + 1
  wend
  py2 = py2 + 1
wend
