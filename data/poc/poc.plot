set term postscript eps color size 6,4.5
set output 'pocG.eps'
set xlabel 'time (in sec)' font ',18'
set ylabel 'block cache hits and misses' font ',18'

set key top right
set key box
set key font ',18'

set tics font ',18'

set grid

set style data histogram
set style histogram rowstacked
set style fill solid
set boxwidth 0.5

plot "poc.dat" using 2 title "block cache hits" lt rgb "#40FF00", "" using 3:xticlabels(1) title "cache misses" lt rgb "#406090"

set output 'pocR.eps'
plot "poc.dat" using 4 title "block cache hits" lt rgb "#40FF00", "" using 5:xticlabels(1) title "cache misses" lt rgb "#406090"

# green "#40FF00"
# blue "#406090"