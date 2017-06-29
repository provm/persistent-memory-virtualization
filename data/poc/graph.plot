set terminal postscript eps color
set output 'distribution.eps'

set yrange[0:22]
set xrange[0:60000]

set style fill solid 1.0 noborder

set ylabel 'Access frequency' font ',18'
set xlabel 'Block number' font ',18'
#set title 'Distribution of read miss time'

set key font ',18'
set tics font ',18'

set boxwidth 1 absolute

plot 'G2.dat' using 1:(1) smooth frequency with boxes title "Block access frequency (for 135385 block accesses)" lt rgb "#406090"