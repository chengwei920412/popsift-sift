#!/bin/bash

VLF=/home/griff/GIT/vlfeat/bin/glnxa64/sift
POP=/home/griff/GIT/popsift/build/Linux-x86_64/popsift-demo

run_vlfeat() {
    file="$1"

    echo ${VLF} -v ${file}.pgm
    ${VLF} -v ${file}.pgm
    sort -n ${file}.sift > tmp/${file}-vlfeat.sift
    rm ${file}.sift
    awk -e '{printf("%f %f %f %f\n",$1,$2,$3,$4);}' < tmp/${file}-vlfeat.sift > tmp/coord-${file}-vlfeat.txt
    awk -f awk/compute.awk tmp/${file}-vlfeat.sift > tmp/sum-${file}-vlfeat.txt
    echo "LEAVE VLFEAT"
}

run_popsift() {
    file="$1"
    par="$2"

    # VLFeat multiplies the descriptors with 512 before converting to uchar,
    # so we use 9 for a 2**9 multiplier as well.
    PAR0="--pgmread-loading --norm-mode=classic --norm-multi 9 --write-as-uchar --write-with-ori --initial-blur 0.5 --sigma 1.6 --threshold 0 --edge-threshold 10.0"

    echo ${POP} ${PAR0} ${par} -i ${file}.pgm
    ${POP} ${PAR0} ${par} -i ${file}.pgm
    sort -n output-features.txt > tmp/${file}-popsift.sift
    rm output-features.txt
    awk -e '{printf("%f %f %f %f\n",$1,$2,$3,$4);}' < tmp/${file}-popsift.sift > tmp/coord-${file}-popsift.txt
    awk -f awk/compute.awk tmp/${file}-popsift.sift > tmp/sum-${file}-popsift.txt
    echo "LEAVE POPSIFT"
}

mkdir -p tmp

# for TESTNAME in default new twobins vlfeatdesc vlfeat
for TESTNAME in new vlfeatdesc
do

    rm -f hash.sift*
    rm -f level1.sift*
    rm -f coord-*
    rm -f sum-*

    # FILES="hash level1 boat"
    # FILES="level1"
    # FILES="hash"
    FILES="boat"
    # FILES="boat1"

    for file in ${FILES} ; do
        if [ "$TESTNAME" = "default" ]; then
	    echo "Test is default"
	    PAR1=" "
        elif [ "$TESTNAME" = "new" ]; then
	    echo "Test is new: loopdescriptor and BestBin"
	    PAR1="--desc-mode=loop"
        elif [ "$TESTNAME" = "vlfeatdesc" ]; then
	    echo "Test is vlfeatdesc: vlfeat descriptor and BestBin"
	    PAR1="--desc-mode=vlfeat"
        else
	    echo "Test is undefined, $TESTNAME"
	    exit
        fi

    	run_vlfeat ${file}

    	run_popsift ${file} ${PAR1}

	echo "Perform brute force matching"
	echo ./compareSiftFiles ${file}-popsift.sift ${file}-vlfeat.sift
	./compareSiftFiles -o tmp/UML-${file}.txt \
	                   -d tmp/descdist-${file}-${TESTNAME}.txt \
	                   tmp/${file}-popsift.sift \
	                   tmp/${file}-vlfeat.sift

	echo "Sorting"
	sort -k3  -g tmp/UML-${file}.txt > tmp/sort-${file}-by-1st-match.txt
	sort -k6  -g tmp/UML-${file}.txt > tmp/sort-${file}-by-pixdist.txt
	sort -k8  -g tmp/UML-${file}.txt > tmp/sort-${file}-by-angle.txt
	sort -k10 -g tmp/UML-${file}.txt > tmp/sort-${file}-by-2nd-match.txt

	echo "Converting descriptor distance stats"
	awk -vCOL=3  -f awk/desc-to-heat.awk tmp/descdist-${file}-${TESTNAME}.txt >  descdist-${file}-${TESTNAME}.txt
	awk -vCOL=4  -f awk/desc-to-heat.awk tmp/descdist-${file}-${TESTNAME}.txt >> descdist-${file}-${TESTNAME}.txt
	awk -vCOL=5  -f awk/desc-to-heat.awk tmp/descdist-${file}-${TESTNAME}.txt >> descdist-${file}-${TESTNAME}.txt
	awk -vCOL=6  -f awk/desc-to-heat.awk tmp/descdist-${file}-${TESTNAME}.txt >> descdist-${file}-${TESTNAME}.txt
	awk -vCOL=7  -f awk/desc-to-heat.awk tmp/descdist-${file}-${TESTNAME}.txt >> descdist-${file}-${TESTNAME}.txt
	awk -vCOL=8  -f awk/desc-to-heat.awk tmp/descdist-${file}-${TESTNAME}.txt >> descdist-${file}-${TESTNAME}.txt
	awk -vCOL=9  -f awk/desc-to-heat.awk tmp/descdist-${file}-${TESTNAME}.txt >> descdist-${file}-${TESTNAME}.txt
	awk -vCOL=10 -f awk/desc-to-heat.awk tmp/descdist-${file}-${TESTNAME}.txt >> descdist-${file}-${TESTNAME}.txt

	echo "Calling gnuplot (pixdist)"
	echo "set title \"L2 distance between pixels, PopSift ${TESTNAME} vs VLFeat" > cmd.gp
	echo "set xlabel \"Keypoint index sorted by closest best match\"" >> cmd.gp
	echo "set logscale y" >> cmd.gp
	echo "set terminal png" >> cmd.gp
	echo "set output \"sort-${file}-by-pixdist-${TESTNAME}.png\"" >> cmd.gp
	echo "plot \"tmp/sort-${file}-by-pixdist.txt\" using (\$6+0.00001) notitle" >> cmd.gp
	gnuplot cmd.gp

	echo "Calling gnuplot (1st dist)"
	echo "set title \"L2 distance between descriptors, PopSift ${TESTNAME} vs VLFeat" > cmd.gp
	echo "set xlabel \"Keypoint index sorted by closest best match\"" >> cmd.gp
	echo "set terminal png" >> cmd.gp
	echo "set output \"/dev/null\"" >> cmd.gp
	echo "plot   \"tmp/sort-${file}-by-1st-match.txt\" using 3 title \"best distance\"" >> cmd.gp
	echo "replot \"tmp/sort-${file}-by-1st-match.txt\" using 10 title \"2nd best distance\"" >> cmd.gp
	echo "set output \"sort-${file}-by-1st-match-${TESTNAME}.png\"" >> cmd.gp
	echo "replot" >> cmd.gp
	gnuplot cmd.gp

	echo "Calling gnuplot for angular diff (1st dist)"
	echo "set title \"Distance in degree between orientations, PopSift ${TESTNAME} vs VLFeat" > cmd.gp
	echo "set ylabel \"Difference (degree)\"" >> cmd.gp
	echo "set xlabel \"Keypoint index sorted by orientation difference\"" >> cmd.gp
	echo "set grid" >> cmd.gp
	echo "set logscale y" >> cmd.gp
	echo "set yrange [0.001:*]" >> cmd.gp
	echo "set style data lines" >> cmd.gp
	echo "set terminal png" >> cmd.gp
	echo "set output \"sort-${file}-by-angle-${TESTNAME}.png\"" >> cmd.gp
	echo "plot \"tmp/sort-${file}-by-angle.txt\" using 8 notitle" >> cmd.gp
	gnuplot cmd.gp

	echo "Calling gnuplot (2nd dist)"
	echo "set title \"L2 distance between descriptors, PopSift ${TESTNAME} vs VLFeat" > cmd.gp
	echo "set xlabel \"Keypoint index sorted by 2nd best match\"" >> cmd.gp
	echo "set terminal png" >> cmd.gp
	echo "set output \"/dev/null\"" >> cmd.gp
	echo "plot   \"tmp/sort-${file}-by-2nd-match.txt\" using 3 title \"best distance\"" >> cmd.gp
	echo "replot \"tmp/sort-${file}-by-2nd-match.txt\" using 10 title \"2nd best distance\"" >> cmd.gp
	echo "set output \"sort-${file}-by-2nd-match-${TESTNAME}.png\"" >> cmd.gp
	echo "replot" >> cmd.gp
	gnuplot cmd.gp

	echo "Calling gnuplot (descriptor summary)"
	echo "set view 80, 20, 1, 1.48" > cmd.gp
	echo "set xrange [ -1.5 : 1.5 ]" >> cmd.gp
	echo "set yrange [ -1.5 : 1.5 ]" >> cmd.gp
	echo "set zrange [ -5 : 5 ]" >> cmd.gp
	echo "set xtics -1.5,3 offset 0,-0.5" >> cmd.gp
	echo "set ytics 1.5,3 offset 0.5" >> cmd.gp
	echo "set ztics -3,3" >> cmd.gp
	echo "set ticslevel 0" >> cmd.gp
	echo "set format cb '%4.1f'" >> cmd.gp
	echo "unset colorbox" >> cmd.gp
	echo "set pm3d implicit at s" >> cmd.gp
	echo "set terminal png size 1080, 250" >> cmd.gp
	echo "set output \"descdist-${file}-${TESTNAME}.png\"" >> cmd.gp
	echo "set multiplot layout 1,8 title '8 bins in each of 16 sections'" >> cmd.gp
	echo "set title 'bin 0 '" >> cmd.gp
	echo "splot \"descdist-${file}-${TESTNAME}.txt\" index 0 using 1:2:3:3 with pm3d notitle" >> cmd.gp
	echo "set title 'bin 1 '" >> cmd.gp
	echo "splot \"descdist-${file}-${TESTNAME}.txt\" index 1 using 1:2:3:3 with pm3d notitle" >> cmd.gp
	echo "set title 'bin 2 '" >> cmd.gp
	echo "splot \"descdist-${file}-${TESTNAME}.txt\" index 2 using 1:2:3:3 with pm3d notitle" >> cmd.gp
	echo "set title 'bin 3 '" >> cmd.gp
	echo "splot \"descdist-${file}-${TESTNAME}.txt\" index 3 using 1:2:3:3 with pm3d notitle" >> cmd.gp
	echo "set title 'bin 4 '" >> cmd.gp
	echo "splot \"descdist-${file}-${TESTNAME}.txt\" index 4 using 1:2:3:3 with pm3d notitle" >> cmd.gp
	echo "set title 'bin 5 '" >> cmd.gp
	echo "splot \"descdist-${file}-${TESTNAME}.txt\" index 5 using 1:2:3:3 with pm3d notitle" >> cmd.gp
	echo "set title 'bin 6 '" >> cmd.gp
	echo "splot \"descdist-${file}-${TESTNAME}.txt\" index 6 using 1:2:3:3 with pm3d notitle" >> cmd.gp
	echo "set title 'bin 7 '" >> cmd.gp
	echo "splot \"descdist-${file}-${TESTNAME}.txt\" index 7 using 1:2:3:3 with pm3d notitle" >> cmd.gp
	gnuplot cmd.gp

	rm -f cmd.gp
    done
done

