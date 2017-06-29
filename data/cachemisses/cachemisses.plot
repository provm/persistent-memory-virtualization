set term postscript eps color
set output 'cachemisses.eps'
#set title 'Time taken for balloon inflation/deflation'
set xlabel 'ssd-balloon command' font ',18'
set ylabel 'number of sectors' font ',18'

set key top left
set key box
set key font ',18'

set tics font ',18'

set grid

set style data histogram
set style histogram cluster gap 1.5
set style fill solid
set boxwidth 1 relative

#set logscale y

plot "cachemisses.dat" using 2:xtic(1) title "balloon size" lt rgb "#40FF00", "" using 3 title "cache misses" lt rgb "#406090"

# green "#40FF00"
# blue "#406090"