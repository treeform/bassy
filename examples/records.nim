import bassy

block:
  let program = compile("""
TYPE PlayerState
  hp AS INTEGER
  x AS FIXED
  y AS FIXED
  name AS STRING
END TYPE

DIM player AS PlayerState
DIM players(3) AS PlayerState
player.hp = 100
player.x = 12.5
player.y = 8
player.name = "Ada"
players(2).hp = player.hp - 25
players(2).name = player.name
""")
  var runtime = initRuntime(program)
  discard runtime.run
  doAssert runtime.getGlobal("player.hp") == 100
  doAssert runtime.getGlobalValue("player.x").asFixed == 12.5'fx
  doAssert runtime.getArray("players.hp", 2) == 75
  doAssert runtime.getStringArray("players.name", 2) == "Ada"
