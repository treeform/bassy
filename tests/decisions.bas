rem A bot's decision, modelled on an arena hero: every decision scans the
rem objects the host can see through one query per field, scores them,
rem and picks something to do. The host restarts the VM between
rem decisions, so globals and arrays carry over and everything else starts
rem afresh.

dim reach(3)
dim table(599)
if ready = 0 then
  ready = 1
  for index = 0 to 599
    table(index) = index * 3 mod 101
  next index
  reach(0) = 2
  reach(1) = 6
  reach(2) = 3
  reach(3) = 9
end if

sub weigh(kind, hp, distance)
  score = 1000 - distance * 3
  if kind = 3 then
    score = score + 200
    if hp <= selfDamage and distance <= hitReach * hitReach then
      score = score + 650
    end if
  elseif kind = 2 then
    if distance <= (hitReach + 2) * (hitReach + 2) or hp < selfDamage * 4 then
      score = score + 1000
    else
      score = score + 80
    end if
  elseif kind = 4 or kind = 5 then
    score = score + 2000
  end if
end sub

selfX = selfInfo(0)
selfY = selfInfo(1)
selfTeam = selfInfo(2)
selfId = selfInfo(3)
selfDamage = selfInfo(4)
hitReach = reach(selfInfo(5) mod 4)

bestId = 0
bestScore = -1000000
threatDistance = 1000000
friendPower = 2
enemyPower = 0
homeThreat = 0
for index = 0 to objectCount() - 1
  hp = objectHp(index)
  if hp > 0 then
    id = objectId(index)
    kind = objectKind(index)
    x = objectX(index)
    y = objectY(index)
    dx = x - selfX
    dy = y - selfY
    distance = dx * dx + dy * dy
    if objectTeam(index) = selfTeam then
      if kind = 1 then
        homeX = x
        homeY = y
      elseif kind = 2 and id <> selfId and distance <= 100 then
        friendPower = friendPower + 2
      end if
    else
      if kind = 2 or kind = 3 then
        if distance < threatDistance then threatDistance = distance
        if kind = 2 and distance <= 100 then enemyPower = enemyPower + 2
        hx = x - homeX
        hy = y - homeY
        if hx * hx + hy * hy < 144 then homeThreat = homeThreat + 1
      end if
      if distance <= 900 then
        weigh(kind, hp, distance)
        if id = lastTarget then score = score + 70
        if score > bestScore then
          bestScore = score
          bestId = id
          bestX = x
          bestY = y
        end if
      end if
    end if
  end if
next index

if bestId <> 0 and enemyPower <= friendPower then
  action = 1
  lastTarget = bestId
elseif homeThreat > 0 then
  action = 2
else
  action = 3
end if
status$ = "target " + str$(bestId) + " at " + str$(bestScore)
if action <> lastAction then
  mood$ = "switch to " + str$(action)
  moods = moods + len(mood$)
end if
lastAction = action
decisions = decisions + 1
tally = (tally * 31 + bestId * 7 + action + threatDistance mod 97 + _
  table(bestId mod 600) + len(status$)) mod 1000003
