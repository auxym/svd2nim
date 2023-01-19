import std/unittest
import std/macros
import std/tables
import std/strutils
import std/sequtils
import regex

import ./utils

include atsamd21g18a

proc parseAddrsFile(fname: static[string]): Table[string, int] =
  var mt: RegexMatch
  for line in staticRead(fname).strip.splitLines:
    if not line.match(re"([._0-9A-Za-z]+):(0[xX][0-9A-Fa-f]+)", mt): continue
    let
      regname = mt.group(0, line)[0]
      regAddr = mt.group(1, line)[0].parseHexInt
    doAssert regName notin result
    result[regName] = regAddr

macro genAddressAsserts(): untyped =
  result = nnkStmtList.newTree()

  let cAddrTable = parseAddrsFile "./addrs.txt"
  assert cAddrTable.len == 1258
  for (regName, regAddr) in cAddrTable.pairs:
    let
      regNameParts = regName.split('.').map(sanitizeIdent)
      dotNode = parseStmt(regNameParts.join(".") & ".loc")
      eqNode = infix(dotNode, "==", newIntLitNode(regAddr))
    result.add newCall("doAssert", eqNode)

    # print out the asserts at runtime for debugging
    #result.add newCall("echo", eqNode.toStrLit)

suite "Integration tests":

  test "Check register addresses":
    genAddressAsserts()