iverilog -g2012 -o sim design.sv tb.sv
vvp sim
gtkwave wave.vcd wave.gtkw