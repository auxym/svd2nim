# svd2nim

Convert [ARM CMSIS-SVD](https://arm-software.github.io/CMSIS_5/SVD/html/index.html) files to Nim register memory mappings.

svd2nim is a tool that generates Nim modules providing access to microcontroller
peripheral registers. This is a low-level building block used for writing
peripheral drivers in Nim.  Therefore, svd2nim is similar to
[svd2rust](https://github.com/rust-embedded/svd2rust) (Rust),
[regz](https://github.com/ZigEmbeddedGroup/regz) (Zig) and [ARM Devtools
svdconv](https://github.com/Open-CMSIS-Pack/devtools) (C).

## Goals

* Conform to the CMSIS-SVD spec in order to be compatible with all Cortex-M
  devices, given that the SVD file is conforming.

* Provide a high-performance yet type-safe API for low level register access.

This project also aims to provide Nim bindings for CMSIS `core_*.h` headers,
which provide access to peripherals that are common to a given Cortex-M core,
such as the NVIC (interrupt controller) and the SysTick timer.

## Building

Install Nim and Nimble: see https://nim-lang.org/install.html. Then,

```bash
git clone https://github.com/auxym/svd2nim
cd svd2nim
nimble install -d
nimble build
```

The svd2nim binary will be created in the `./build` subdirectory.

## Usage

```
svd2nim - Generate Nim peripheral register APIs for ARM using CMSIS-SVD files.

  Usage:
    svd2nim [options] <SvdFile>
    svd2nim (-h | --help)
    svd2nim (-v | --version)

  Options:
    -h --help           Show this screen.
    -v --version        Show version.
    -o DIR              Specify output directory for generated files. (default: ./)
    --ignore-prepend    Ignore peripheral <prependToName>
    --ignore-append     Ignore peripheral <appendToName>
```

Three files will be generated by svd2nim in the output directory:

* The "device" module (eg. `atsamd21g18a.nim`), which is the main module
  containing the register access API.

* The "core" module (eg. `core_cm0plus.nim`), see
  [Core header bindings](#core-header-bindings).

* `uncheckedenums.nim`, which is a dependency of the device module. See
  [Unchecked Enums](#unchecked-enums).

## API


First, a short usage example, inspired by [Thea Flowers's blog post on the
SAMD21 clock system](https://blog.thea.codes/understanding-the-sam-d21-clocks/).

```nim
# Import device module generated by svd2nim
import atsamd21g18a

proc initDfll48m*() =
  # Modify a single bitfield in a register (read-modify-write operation)
  # Here we set the number of wait states for the flash (NVM) controller
  NVMCTRL.CTRLB.modifyIt:
    it.RWS = HALF

  # Write a full register value, specifying all bitfield values
  # Configure the external 32 kHz oscillator peripheral settings
  # Note: Explicitly set ONDEMAND=false because the argument default is true
  SYSCTRL.XOSC32K.write(
    XTALEN=true, STARTUP=0x7, EN32K=true, ONDEMAND=false
  )

  # Enable external 32 kHz oscillator (read-modify-write operation)
  SYSCTRL.XOSC32K.modifyIt:
    it.ENABLE = true

  # Read a boolean bitfield from a register (wait until the external 32 kHz
  # oscillator is ready for operation).
  while not SYSCTRL.PCLKSR.read().XOSC32KRDY: discard

  # (...)
```

The Nim module generated by svd2nim tries to stay close to CMSIS conventions
when it makes sense to do so. However, Nim does not map 1:1 to C (in particular,
for marking struct members `volatile` or `const`, and for anonymous unions),
therefore the API is not identical to CMSIS C `device.h` headers.

The Nim API has was designeed with two main goals:

1. As close as possible to zero performance cost for accessing registers,
   compared to using C headers directly.

2. Use Nim's type system to provide as much safety as possible while still
   respecting goal #1.

The examples below are taken from the Nim module generated from the
`ATSAMD21G18A.svd` file found under the `tests` folder of the repository.

### Peripheral Objects

For each peripheral, a `const` object is defined, each member is either a
register or cluster (a container type for other registers).

```nim
const GCLK* = GCLK_Type(
  CTRL: GCLK_CTRL_Type(loc: 0x40000c00),
  STATUS: GCLK_STATUS_Type(loc: 0x40000c01),
  CLKCTRL: GCLK_CLKCTRL_Type(loc: 0x40000c02),
  GENCTRL: GCLK_GENCTRL_Type(loc: 0x40000c04),
  GENDIV: GCLK_GENDIV_Type(loc: 0x40000c08),
)
```

Note that all fields are marked public.

Cluster objects are similar to Peripherals: they are "container" objects that
contain either registers or other clusters. svd2nim supports clusters nested arbitrarily deep.

Registers are also `object` types. However, registers contain a
single field, which is the address (`loc`) to the memory-mapped register,
represented as `uint`. Example:

```nim
type GCLK_GENDIV_Type = object
  loc: uint
```

Note that the `loc` field is *private*. Indeed, registers are only intended to
be accessed using accessor templates described in the following section. This
allows:

* Using Nim's type system to enforce register access (read-only, write-only,
  read/write) permissions specified in the SVD file.

* Automatically calling `volatileLoad` and `volatileStore` calls for reads
  and writes.

* Convenient access to bitfields, also described below.

### Accessors

As noted above, registers can only be read or written using generated accessor
procs. For each register object type, either a `read` proc, a
`write` proc, or both may be generated, depeding on the register access
permissions defined by the SVD file. Example (for a read/write register):

```nim
proc read*(reg: ADC_WINLT_Type): uint16 {.inline.} =
  volatileLoad(cast[ptr uint16](reg.loc))

proc write*(reg: ADC_WINLT_Type, val: uint16) {.inline.} =
  volatileStore(cast[ptr uint16](reg.loc), val)
```

### Bitfields

SVD registers may define `field` elements, which means that the register value
is split into bitfields. For these registers, svd2nim generates a distinct
integer type which is used as the register value type (for `read`/`write`)
instead of the base integer type. Example:

```nim
type
  # (...)
  GCLK_GENDIV_Fields* = distinct uint32
```

Each bitfield of the distinct type can be read or set using bitfield accessors.
Here, the `GCLK_GENDIV` register defines 2 fields: `ID` (bits 0-3) and `DIV`
(bits 8-23). Other bits are unused (reserved). The accessors generated are:

```nim
func ID*(r: GCLK_GENDIV_Fields): uint32 {.inline.} =
  r.uint32.bitsliced(0 .. 3)

proc `ID=`*(r: var GCLK_GENDIV_Fields, val: uint32) {.inline.} =
  var tmp = r.uint32
  tmp.clearMask(0 .. 3)
  tmp.setMask((val shl 0).masked(0 .. 3))
  r = tmp.GCLK_GENDIV_Fields

# Note: `div` is a reserved keyword in Nim, so DIVx is used
# to avoid the conflict.
func DIVx*(r: GCLK_GENDIV_Fields): uint32 {.inline.} =
  r.uint32.bitsliced(8 .. 23)

proc `DIVx=`*(r: var GCLK_GENDIV_Fields, val: uint32) {.inline.} =
  var tmp = r.uint32
  tmp.clearMask(8 .. 23)
  tmp.setMask((val shl 8).masked(8 .. 23))
  r = tmp.GCLK_GENDIV_Fields
```

Credit goes to the
[cdecl/bitfields](https://elcritch.github.io/cdecl/cdecl/bitfields.html)
library, which strongly inspired this approach to handling bitfields, due to
[issues](https://lwn.net/Articles/478657/) with "native" C bitfields.

svd2nim generates *two* `write` accessors for registers that are writable and
define fields. One takes a full value (the distinct integer type) and the second
takes a separate value for each field, with a default value equal to the
register's reset value for that field as defined by the SVD. Example:

```nim
proc write*(reg: GCLK_GENDIV_Type, val: GCLK_GENDIV_Fields) {.inline.} =
  volatileStore(cast[ptr GCLK_GENDIV_Fields](reg.loc), val)

proc write*(reg: GCLK_GENDIV_Type, ID: uint32 = 0, DIVx: uint32 = 0) =
  var x: uint32
  x.setMask((ID shl 0).masked(0 .. 3))
  x.setMask((DIVx shl 8).masked(8 .. 23))
  reg.write x.GCLK_GENDIV_Fields
```

Finally, for convenience when doing a read-modify-write operation, a `modifyIt`
template is also generated for read-write registers with fields. Similarly to
the the `*it` templates in Nim's `std/sequtils` module, `modifyIt` reads the
register and stores its value in the `it` variable. The `op` parameter passed to
the template can then modify `it`. Finally, `it` is written back to the
register. Example template code:

```nim
template modifyIt*(reg: GCLK_GENDIV_Type, op: untyped): untyped =
  block:
    var it {.inject.} = reg.read()
    op
    reg.write(it)
```

This allows modifying mutliple fields with a **single read-modify-write
operation**.

**IMPORTANT NOTE**: [Due to a currently open Nim
bug](https://github.com/nim-lang/Nim/issues/14623) related to `volatileStore`
and `volatileLoad`, calling `modifyIt` from the top-level in a module results in
incorrect codegen by the Nim compiler and in C compiler errors. The workaround
is simple: ensure that all calls are made from inside a `proc`.

### Unchecked Enums

Some bitfields have associated enum types defined by the SVD file. svd2nim
generates these as Nim enum types, and uses the type for the bitfield accessors
described above.

However, when reading a bitfield, we cannot guarantee that converting the
resulting numerical value to the enum type will succeed. The numerical value may
be invalid for the enum type: a 4-bit bitfield may read `11` when only values
`0` through `10` are defined in the enum type.

For this reason, accessors generated by svd2nim for bitfields with enum value
types return `UncheckedEnum[FieldEnumType]` instead of trying to convert directly
to `FieldEnumType` (and possibly failing).

The `uncheckedenums` module provides procs to convert unchecked enums to their
base enum type but also work with unchecked enum values directly, as conversion
is often uneeded (eg. for comparison):

```nim
import atsamd21g18a
import uncheckedenums

# A holey enum
type ADC_COMPCTRL_MUXPOS* {.size: 4.} = enum
  muxPIN0 = 0x0,
  muxPIN1 = 0x1,
  muxPIN2 = 0x2,
  # (...)
  muxDAC = 0x1c,

let muxpos: UncheckedEnum[ADC_COMPCTRL_MUXPOS] = AC.COMPCTRL0.read().MUXPOS

# Can be compared directly with an enum value, without converting
if muxpos == muxPIN2:
  # do something
  discard

# We can use `get` for converting to the underlying enum type,
# ADC_COMPCTRL_MUXPOS. `get` will raise a Defect if the value is invalid, so you
# likely want to check `isValid` first.
if muxPos.isValid:
  case muxPos.get:
  of muxPIN0:
    discard
  of muxPIN1:
    discard
  else:
    discard
else:
  # Handle invalid value
  discard
```

For more information, see the `uncheckedenums.nim` file.

### More Examples

  * [The complete code to enable the 48 MHz DFLL clock on SAMD21](https://github.com/auxym/nim-on-samd21/blob/master/src/clocks.nim)

  * [SAMD21 GPIO driver leveraging macros](https://github.com/auxym/nim-on-samd21/blob/master/src/port.nim)

### Core Header Bindings

The "core" C header file for a given ARM Cortex-M CPU  (eg, `core_cm0plus.h`
for Cortex-M0+) contains functions related to peripherals that are common to
the CPU core, such as the NVIC (interrupt controller) and the SysTick Timer.

When `svd2nim` is called, a second file (eg.  `core_cm0plus.nim`), containing
bindings for the core header, will be generated in the same output directory as
the main device module. Import the core Nim module requires that the
corresponding C headers can be found by the C compiler (eg. by passing
`--passC:-I./lib/CMSIS/Core/Include` to the Nim compiler). The CMSIS headers can
be obtained from:

https://github.com/ARM-software/CMSIS_5/tree/develop/CMSIS/Core/Include

And are documented here:
https://arm-software.github.io/CMSIS_5/Core/html/modules.html

See the [nim-on-samd21 repository](https://github.com/auxym/nim-on-samd21) for
an example on building the Nim core bindings against the CMSIS headers.

Currently only the `core_cm0plus.nim` module, for Cortex-M0+ CPUs, is provided
by svd2nim , but PRs are welcome for others.

## License

Unless specified otherwise in specific files, svd2nim is distributed under the
terms of the MIT license. See `LICENSE` file for the full terms and copyright
notice.

The SVD files under the *tests* directory are copyright of their respective
authors and used under license, as specified in each file.
