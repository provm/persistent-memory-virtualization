set term postscript eps color
set output 'ballooning.eps'
#set title 'Time taken for balloon inflation/deflation'
set xlabel 'balloon size (in GB)' font ',18'
set ylabel 'time (in s) (log scale)' font ',18'

set key top left
set key box
set key font ',18'

set tics font ',18'

set grid

set style data histogram
set style histogram cluster gap 1.5
set style fill solid
#set boxwidth 0.5

set logscale y

plot "ballooning.dat" using 4:xtic(1) title "inflation" lt rgb "#40FF00", "" using 5 title "deflation" lt rgb "#406090"

# green "#40FF00"
# blue "#406090"