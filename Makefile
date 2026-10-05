.PHONY: test lint synth clean

test:
	$(MAKE) -C test

lint:
	verilator --lint-only --Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
		--top-module tt_um_dwallener_sensor \
		src/project.v src/mono_temporal_core.v

synth:
	yosys -q -p 'read_verilog src/project.v src/mono_temporal_core.v; hierarchy -check -top tt_um_dwallener_sensor; proc; opt; memory; opt; techmap; opt; stat'

clean:
	$(MAKE) -C test clean
