#!/usr/bin/env nextflow

Channel
    .fromFilePairs( params.reads, size: (params.single_end || params.interleaved) ? 1 : 2 )
    .ifEmpty { exit 1, "Cannot find any reads matching: ${params.reads}." }
    .set { raw_reads_deinterleave_ch } // .into for two or more target channels

Channel
    .fromPath( "${params.kraken2_db}", checkIfExists: true, type: 'dir')
    .into { kraken2_db_kraken2_ch; kraken2_db_bracken_ch  }

/*
 * Step 0. Deinterleave paired reads
 */
if (params.interleaved) {
    process deinterleave {      
        tag "${id}"

        input:
        tuple val(id), path(reads) from raw_reads_deinterleave_ch

        output:
        tuple val(id), path("read_*.fastq.gz") into raw_reads_stats_ch, raw_reads_adapter_ch

        script:
        task_memory_GB = task.memory.toGiga()
        
        """
        reformat.sh \
            -Xmx${task_memory_GB}g \
            in=$reads \
            out1=read_1.fastq.gz \
            out2=read_2.fastq.gz \
            t=1
        """
    }
} else {
    raw_reads_deinterleave_ch.into { raw_reads_stats_ch; raw_reads_kraken2_ch }
}

/*
 * Step 1. Raw reads histograms
 */
process raw_reads_stats {   
    tag "${id}"

    publishDir "${params.outdir}/${id}/raw_reads_stats" , mode: 'copy'

    input:
    tuple val(id), path(reads) from raw_reads_stats_ch

    output:
    path "*hist.txt"

    script:
    task_memory_GB = task.memory.toGiga()
    input = params.single_end ? "in=\"$reads\"" : "in1=\"${reads[0]}\" in2=\"${reads[1]}\""
    """
    bbduk.sh \
        -Xmx${task_memory_GB}g \
        $input \
        bhist=bhist.txt \
        qhist=qhist.txt \
        gchist=gchist.txt \
        aqhist=aqhist.txt \
        lhist=lhist.txt \
        gcbins=auto
    """
}

raw_reads_kraken2_ch.combine(kraken2_db_kraken2_ch).set{ merged_kraken2_ch }

/*
 * Step 2 Kraken2
 */
process kraken2 {
    tag "${id}"

    publishDir "${params.outdir}/${id}/kraken" , mode: 'copy'

    input:
    tuple val(id), path(reads), path(kraken2_db) from merged_kraken2_ch
    
    output:
    tuple val(id), path("kraken2.report") into kraken2_report_bracken_ch
    path "kraken2.output"
    path "kraken2.krona"

    script:
    input = params.single_end ? "\"$reads\"" :  "---paired \"${reads[0]}\" \"${reads[1]}\""
    report_zero = params.report_zero ? "--report-zero-counts" : ""
    """
    kraken2 \
        --db $kraken2_db \
        --threads ${task.cpus} \
        $report_zero \
        --report kraken2.report \
        $input \
        > kraken2.output

    cut -f 2,3 kraken2.output > kraken2.krona
    """
}

kraken2_report_bracken_ch.combine(kraken2_db_bracken_ch).set{ merged_bracken_ch }

/*
 * Step 3. Bracken
 */
if (!params.skip_bracken) {
    process bracken {
        tag "${id}"
    
        publishDir "${params.outdir}/${id}/bracken" , mode: 'copy'

        input:
        tuple val(id), path(kraken2_report), path(kraken2_db) from merged_bracken_ch

        output:
        path "bracken_?.report"

        script:
        """
        for level in D P C O F G S
        do
            bracken \
                -d $kraken2_db \
                -r ${params.read_len} \
                -l \$level \
                -i $kraken2_report \
                -o bracken_\${level}.report 
        done
        """
    }
}