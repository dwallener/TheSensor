.PHONY: test test-rtl test-audio demo lint synth clean

test: test-rtl test-audio

test-rtl:
	$(MAKE) -C test

test-audio:
	python3 -m pytest -q test/test_audio_model.py

demo:
	python3 sim/run_reference.py

lint:
	verilator --lint-only --Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
		--top-module tt_um_dwallener_sensor \
		src/project.v src/mono_temporal_core.v src/stereo_filterbank_core.v \
		src/visual_field_core.v src/auditory_field_core.v

synth:
	yosys -q -p 'read_verilog src/project.v src/mono_temporal_core.v src/stereo_filterbank_core.v src/visual_field_core.v src/auditory_field_core.v; hierarchy -check -top tt_um_dwallener_sensor; proc; opt; memory; opt; techmap; opt; stat'

clean:
	$(MAKE) -C test clean
