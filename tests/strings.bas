rem A text workload: split sentences into words, then reverse, encode,
rem compare and score every word. It leans on every string function the
rem language has, the way a chatty game script would.

dim words$(15)
checksum = 0
palindromes = 0
repeats = 0
shouts = 0
round = 0
while round < rounds
  sentence = 0
  while sentence < 4
    select case (sentence + round) mod 4
    case 0
      text$ = "the quick brown fox jumps over the lazy dog"
    case 1
      text$ = "a man a plan a canal panama"
    case 2
      text$ = "never odd or even said the racecar driver"
    case else
      text$ = "  pack my box with five dozen liquor jugs  "
    end select
    text$ = trim$(text$)

    rem Split on spaces.
    count = 0
    start = 1
    finish = instr(start, text$, " ")
    while finish > 0
      words$(count) = mid$(text$, start, finish - start)
      count = count + 1
      start = finish + 1
      finish = instr(start, text$, " ")
    wend
    words$(count) = mid$(text$, start)
    count = count + 1

    index = 0
    while index < count
      word$ = words$(index)
      size = len(word$)

      rem Reverse it one letter at a time.
      reversed$ = ""
      letter = size
      while letter > 0
        reversed$ = reversed$ + mid$(word$, letter, 1)
        letter = letter - 1
      wend
      if reversed$ = word$ and size > 1 then palindromes = palindromes + 1

      rem Shift every letter three places along the alphabet.
      coded$ = ""
      letter = 1
      while letter <= size
        code = asc(mid$(word$, letter, 1)) - 97
        coded$ = coded$ + chr$((code + 3) mod 26 + 97)
        letter = letter + 1
      wend

      rem Count words seen earlier in the same sentence.
      earlier = 0
      while earlier < index
        if words$(earlier) = word$ then repeats = repeats + 1
        earlier = earlier + 1
      wend

      if ucase$(word$) = "THE" then shouts = shouts + 1
      checksum = (checksum * 31 + asc(coded$) * size + len(reversed$)) mod 1000003
      index = index + 1
    wend
    checksum = (checksum + len(left$(text$, 5)) + len(right$(text$, 3))) mod 1000003
    sentence = sentence + 1
  wend
  round = round + 1
wend
summary$ = str$(checksum) + str$(palindromes) + str$(repeats) + str$(shouts)
checksum = (checksum + len(summary$)) mod 1000003
