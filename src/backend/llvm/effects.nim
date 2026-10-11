## Conservative diagnostics only. No pending writes or reordered operations.
import std/[json, tables]
import ../../ir/[node, kind]

proc ioReport*(module: Module): JsonNode =
  var externs = initTable[string, Extern]()
  for external in module.externs: externs[external.name] = external
  result = %*{"enabled": false, "formedBatches": 0, "operations": 0,
    "policy": "synchronous; differential and paired benchmark gates pending", "candidates": []}
  let report = result
  for fn in module.funcs:
    for blockValue in fn.blocks:
      var run: seq[Instruction]
      let functionName = fn.name
      let blockName = blockValue.label
      proc finish(reason: string) =
        if run.len == 0: return
        var slots = newJArray()
        for operation in run:
          slots.add(%*{"result": operation.dest.name, "file": operation.span.file,
            "start": operation.span.start, "end": operation.span.end})
        report["operations"] = %(report["operations"].getInt() + run.len)
        report["candidates"].add(%*{"function": functionName, "block": blockName,
          "count": run.len, "handle": run[0].args[0].name, "formed": false,
          "reason": (if run.len < 2: "single operation" else: "disabled: per-operation partial-write/error and benchmark gates pending"),
          "boundary": reason, "slots": slots})
        run.setLen(0)
      for operation in blockValue.instrs:
        let write = operation.kind == InstrKind.Call and externs.hasKey(operation.func) and
          externs[operation.func].abi == "runtime.io" and externs[operation.func].symbol == "write" and
          operation.args.len == 2 and operation.args[0].kind == ValueKind.Reg
        if write:
          if run.len > 0 and (operation.args[0].name != run[0].args[0].name or
              operation.args[0].type != run[0].args[0].type): finish("different or unproven handle")
          run.add(operation)
        else:
          # Even trace, cleanup and pure instructions are boundaries for now.
          # This covers sync/replace/read, spawn/exit, locks and task handoff.
          finish("intervening " & $operation.kind & " is an ordering barrier")
      finish("basic block boundary")
