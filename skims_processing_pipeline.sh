#!/bin/bash

set -e
set -x

out_dir=`pwd`
ref_dir=`pwd`
threads=8
iterations=1000
cores=8
interleaven_counter=0

usage="bash ${BASH_SOURCE[0]} -h [-x input] [-l interleaven_counter] [-g lib_dir] [-r threads] [-d iterations] [-f cores]
Runs nuclear read processing pipeline on a batch of reads split into two mates in reference to a constructed library:
    
    Options:
    -h  show this help text
   
    Mandatory inputs:
    -x  path to folder containing reads (split reads that need to be merged)

    Optional inputs:
    -l  can be set as 0(default) or 1, input 1 if the input directory consists of single interleaved paired-end reads instead of two mate pair reads
    -g  path to reference library
    -r  threads for RESPECT; default: 8
    -d  number of iteration cycles for RESPECT, default: 1000
    -f  number of cores for SKMER, default: 8"

while getopts ":hl:x:r::d::f::g::" opts 
do
    case "$opts" in
	h) echo "$usage"; exit;;
        l) interleaven_counter="$OPTARG";;	
        x) input="$OPTARG";;
        r) threads="$OPTARG";;
	d) iterations="$OPTARG";;
	f) cores="$OPTARG";;
	g) lib_dir="$OPTARG";;
        [?]) echo "invalid input param"; exit 1;;
    esac
done

if [ ! "$input" ]; then
	
	echo "arguments -x must be provided"; exit 1

fi

x=`ls $input`

if [ !$x ]; then
   echo "No files in directory"
   exit
fi

if [ "${input:0-1}" = "/" ]; then

	input=${input%?}

fi

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

if [ ! "$lib_dir" ]; then
	
	if [ ! -d "$ref_dir/library" ]; then	
  		mkdir $ref_dir/library 
	fi
	
	lib_dir=$ref_dir/library

fi

if [ ! -f "$SCRIPT_DIR/log_file.txt" ]; then
	
	echo "Log File for tracking operations">>$SCRIPT_DIR/log_file.txt

fi

if [ ! -f "$lib_dir/CONFIG" ]; then

	echo "kmer_length	31
sketch_size	100000
sketching_seed	42" >$lib_dir/CONFIG

fi

if [ "1" -eq "$interleaven_counter" ]; then
	
	echo "Entered first interleaven block"
	bash ${SCRIPT_DIR}/interleaven.sh ${input} ${ref_dir}
        input=${ref_dir}/interleaven_reads

fi

declare -A array

counter=0

for f in `ls ${input}`;do

        genome=$(basename -- "$f")
        extension="${genome##*.}"
	if [ "$extension" = "gz" ]; then
		genome="${genome%.*}"
		extension="${genome##*.}"
		if [ "$extension" = "fastq" ] || [ "$extension" = "fq" ]; then
			genome="${genome%.*}"
        		genome="${genome%?}"
			key=$genome
			counter=1
		fi
	elif [ "$extension" = "fastq" ] || [ "$extension" = "fq" ]; then
		genome="${genome%.*}"
                genome="${genome%?}"
                key=$genome
		counter=1
	fi

        if [ "1" -eq "$counter" ]; then
		value=$f
        	array[${key}]="${array[${key}]}${array[${key}]:+,}${value}"
		counter=0
	fi

done

direc_name=$(basename "${BASH_SOURCE[0]%.*}") 
mkdir -p ${out_dir}/${direc_name}/{bbmap,respect}

if [ -d "${out_dir}/temp_ops" ]; then

        echo "Temp folder found; removed for later operations"
        rm -r ${out_dir}/temp_ops

fi

source ${SCRIPT_DIR}/conda_source.sh

for key in "${!array[@]}"; do
	
	genome=$key
        genome_value=${array[$key]}
        input_1="${genome_value%,*}"
        input_2="${genome_value#*,}"
	
	mkdir -p ${out_dir}/temp_ops
	cd ${out_dir}/temp_ops

	counter=0

	if [ -f "${out_dir}/${direc_name}/bbmap/${genome}_merged.fq" ]; then

		test_var=0
		test_var=`grep "$genome" $SCRIPT_DIR/log_file.txt | grep -c "A"` || true
		if [ "1" -eq "$test_var" ]; then
			counter=1
		else
			rm ${out_dir}/${direc_name}/bbmap/${genome}_merged.fq
		fi
	fi

	extension="${input_1##*.}"

	if [ "0" -eq "$counter" ]; then
		echo "BBMap cleanup pipeline starts"
		if [ "$extension" = "gz" ]; then
			${SCRIPT_DIR}/bbmap_pipeline.sh ${input}/${input_1} ${input}/${input_2} ${out_dir}/${direc_name}/bbmap/${genome}_merged.fq
			echo "BBMap cleanup pipeline ends"
		else
			${SCRIPT_DIR}/interleaved_bbmap_pipeline.sh ${input}/${input_1} ${input}/${input_2} ${out_dir}/${direc_name}/bbmap/${genome}_merged.fq
			echo "BBMap cleanup pipeline ends"
		fi
		
		if [ -z "`grep "$genome" $SCRIPT_DIR/log_file.txt`" ]; then
                        echo "$genome""A">>$SCRIPT_DIR/log_file.txt
                else
                        var=`grep "$genome" $SCRIPT_DIR/log_file.txt`
                        var1="$genome""IA"
                        sed -i "s/$var/$var1/" $SCRIPT_DIR/log_file.txt
                fi

	else
		echo "BBMap operation on this sample already performed"
	fi

 	cd ${ref_dir}
	rm -r ${out_dir}/temp_ops
	
	f=`ls ${lib_dir} | wc -l`

	mkdir -p ${out_dir}/temp_ops
        cd ${out_dir}/temp_ops

	counter=0

        if [ -d "${lib_dir}/${genome}_merged" ]; then

                test_var=0
		test_var=`grep "$genome" $SCRIPT_DIR/log_file.txt | grep -c "B"` || true
                if [ "1" -eq "$test_var" ]; then
                        counter=1
                else
                        rm -r ${lib_dir}/${genome}_merged
                fi
        fi

	if [ "0" -eq "$counter" ]; then
		
		${SCRIPT_DIR}/skmer_pipeline.sh $f ${out_dir}/${direc_name}/bbmap ${genome}_merged.fq $lib_dir $cores

		var=`grep "$genome" $SCRIPT_DIR/log_file.txt`
        	if [ "1" -eq "$interleaven_counter" ]; then
                	var1="$genome""IAB"
                	sed -i "s/$var/$var1/" $SCRIPT_DIR/log_file.txt
        	else
                	var1="$genome""AB"
                	sed -i "s/$var/$var1/" $SCRIPT_DIR/log_file.txt
        	fi
	else
		echo "Skmer operation on this sample already performed"
	fi

	cd ${ref_dir}
        rm -r ${out_dir}/temp_ops

	cov_val=$(grep coverage ${lib_dir}/${genome}_merged/${genome}_merged.dat |cut -f2)
	
	counter=0

	if [ -d "${out_dir}/${direc_name}/respect/${genome}" ]; then

                test_var=0
		test_var=`grep "$genome" $SCRIPT_DIR/log_file.txt | grep -c "C"` || true
                if [ "1" -eq "$test_var" ]; then
                        counter=1
                else
                        rm -r ${out_dir}/${direc_name}/respect/${genome}
                fi
        fi

	mkdir -p ${out_dir}/${direc_name}/respect/${genome}/output/tmp

	if [ "0" -eq "$counter" ]; then
	
		${SCRIPT_DIR}/respect_pipeline.sh $cov_val $genome $lib_dir ${out_dir}/${direc_name} $iterations $threads
		
		var=`grep "$genome" $SCRIPT_DIR/log_file.txt`
        	if [ "1" -eq "$interleaven_counter" ]; then
                	var1="$genome""IABC"
                	sed -i "s/$var/$var1/" $SCRIPT_DIR/log_file.txt
        	else
                	var1="$genome""ABC"
                	sed -i "s/$var/$var1/" $SCRIPT_DIR/log_file.txt
        	fi
	else
		echo "Respect operation on this sample already performed"
	fi

done

echo "Skmer distance running"
skmer distance ${lib_dir}
echo "Skmer distance done"

echo "Post processing starts" 

${SCRIPT_DIR}/post_processing_pipeline.sh ${SCRIPT_DIR} ${ref_dir} ${direc_name} ${lib_dir}

echo "Post processing done" 

conda deactivate