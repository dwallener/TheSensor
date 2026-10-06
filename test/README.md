# Testbench for The Sensor

The cocotb testbench streams complete current/previous tiles through the ASIC RTL
and checks every response byte against the bit-accurate Python model. It covers
flat fields, oriented patterns, positive and negative temporal change, motion,
stereo auditory features, visual-field translation/expansion/rotation/saliency,
auditory temporal integration and baseline novelty, random inputs, visual/field
output backpressure, B0 fire-and-forget transmission, and invalid commands.

## Setting up

Install the packages in `requirements.txt`. The repository root README shows one
way to use a local virtual environment.

## How to run

To run the RTL simulation:

```sh
make -B
```

To run gatelevel simulation, first harden your project and copy `../runs/wokwi/results/final/verilog/gl/{your_module_name}.v` to `gate_level_netlist.v`.

Then run:

```sh
make -B GATES=yes
```

If you wish to save the waveform in VCD format instead of FST format, edit tb.v to use `$dumpfile("tb.vcd");` and then run:

```sh
make -B FST=
```

This will generate `tb.vcd` instead of `tb.fst`.

## How to view the waveform file

Using GTKWave

```sh
gtkwave tb.fst tb.gtkw
```

Using Surfer

```sh
surfer tb.fst
```
