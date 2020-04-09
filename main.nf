#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/covidhackathon
========================================================================================
 nf-core/covidhackathon Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nf-core/covidhackathon
----------------------------------------------------------------------------------------
*/

def helpMessage() {
    // TODO nf-core: Add to this help message with new command line parameters
    log.info nfcoreHeader()
    log.info"""
    This pipeline aligns viral sequences to human and viral references
    discards reads common to both

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run nf-core/covidhackathon --reads '*_R{1,2}.fastq.gz' -profile docker

    Mandatory arguments:
      --reads [file]                Path to input data (must be surrounded with quotes)
      -profile [str]                Configuration profile to use. Can use multiple (comma separated)
                                    Available: conda, docker, singularity, test, awsbatch and more

    Options:
      --genome [str]                  Name of iGenomes reference
      --single_end [bool]             Specifies that the input is single-end reads

    References                        If not specified in the configuration file or you wish to overwrite any of the references
      --fasta [file]                  Path to fasta reference
      --gtf [file]                    Path to GTF file

    Other options:
      --outdir [file]                 The output directory where the results will be saved
      --email [email]                 Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      --email_on_fail [email]         Same as --email, except only send mail if the workflow is not successful
      --max_multiqc_email_size [str]  Theshold size for MultiQC report to be attached in notification email. If file generated by pipeline exceeds the threshold, it will not be attached (Default: 25MB)
      -name [str]                     Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic

    AWSBatch options:
      --awsqueue [str]                The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion [str]               The AWS Region for your AWS Batch job to run on
      --awscli [str]                  Path to the AWS CLI tool
    """.stripIndent()
}

// Show help message
if (params.help) {
    helpMessage()
    exit 0
}

/*
 * SET UP CONFIGURATION VARIABLES
 */

// Check if genome exists in the config file
if (params.genomes && params.genome && !params.genomes.containsKey(params.genome)) {
    exit 1, "The provided genome '${params.genome}' is not available in the iGenomes file. Currently the available genomes are ${params.genomes.keySet().join(", ")}"
}

// TODO nf-core: Add any reference files that are needed
// Configurable reference genomes
//
// NOTE - THIS IS NOT USED IN THIS PIPELINE, EXAMPLE ONLY
// If you want to use the channel below in a process, define the following:
//   input:
//   file fasta from ch_fasta
//
params.fasta = params.genome ? params.genomes[ params.genome ].fasta ?: false : false
if (params.fasta) { ch_fasta = file(params.fasta, checkIfExists: true) }

params.gtf = params.genome ? params.genomes[ params.genome ].gtf ?: false : false
if (params.gtf) { ch_gtf = file(params.gtf, checkIfExists: true) }

// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if (!(workflow.runName ==~ /[a-z]+_[a-z]+/)) {
    custom_runName = workflow.runName
}

if (workflow.profile.contains('awsbatch')) {
    // AWSBatch sanity checking
    if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
    // Check outdir paths to be S3 buckets if running on AWSBatch
    // related: https://github.com/nextflow-io/nextflow/issues/813
    if (!params.outdir.startsWith('s3:')) exit 1, "Outdir not on S3 - specify S3 Bucket to run on AWSBatch!"
    // Prevent trace files to be stored on S3 since S3 does not support rolling files.
    if (params.tracedir.startsWith('s3:')) exit 1, "Specify a local tracedir or run without trace! S3 cannot be used for tracefiles."
}

// Stage config files
ch_multiqc_config = file(params.multiqc_config, checkIfExists: true)
ch_output_docs = file("$baseDir/docs/output.md", checkIfExists: true)

/*
 * Create a channel for input read files
 */
if (params.readPaths) {
    if (params.single_end) {
        Channel
            .from(params.readPaths)
            .map { row -> [ row[0], [ file(row[1][0], checkIfExists: true) ] ] }
            .ifEmpty { exit 1, "params.readPaths was empty - no input files supplied" }
            .into { ch_read_files_fastqc; ch_read_files_trimming }
    } else {
        Channel
            .from(params.readPaths)
            .map { row -> [ row[0], [ file(row[1][0], checkIfExists: true), file(row[1][1], checkIfExists: true) ] ] }
            .ifEmpty { exit 1, "params.readPaths was empty - no input files supplied" }
            .into { ch_read_files_fastqc; ch_read_files_trimming }
    }
} else {
    Channel
        .fromFilePairs(params.reads, size: params.single_end ? 1 : 2)
        .ifEmpty { exit 1, "Cannot find any reads matching: ${params.reads}\nNB: Path needs to be enclosed in quotes!\nIf this is single-end data, please specify --single_end on the command line." }
        .into { ch_read_files_fastqc; ch_read_files_trimming }
}

// Header log info
log.info nfcoreHeader()
def summary = [:]
if (workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Run Name']         = custom_runName ?: workflow.runName
// TODO nf-core: Report custom parameters here
summary['Reads']            = params.reads
summary['Fasta Ref']        = params.fasta
summary['Data Type']        = params.single_end ? 'Single-End' : 'Paired-End'
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if (workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Output dir']       = params.outdir
summary['Launch dir']       = workflow.launchDir
summary['Working dir']      = workflow.workDir
summary['Script dir']       = workflow.projectDir
summary['User']             = workflow.userName
if (workflow.profile.contains('awsbatch')) {
    summary['AWS Region']   = params.awsregion
    summary['AWS Queue']    = params.awsqueue
    summary['AWS CLI']      = params.awscli
}
summary['Config Profile'] = workflow.profile
if (params.config_profile_description) summary['Config Description'] = params.config_profile_description
if (params.config_profile_contact)     summary['Config Contact']     = params.config_profile_contact
if (params.config_profile_url)         summary['Config URL']         = params.config_profile_url
if (params.email || params.email_on_fail) {
    summary['E-mail Address']    = params.email
    summary['E-mail on failure'] = params.email_on_fail
    summary['MultiQC maxsize']   = params.max_multiqc_email_size
}
log.info summary.collect { k,v -> "${k.padRight(18)}: $v" }.join("\n")
log.info "-\033[2m--------------------------------------------------\033[0m-"

// Check the hostnames against configured profiles
checkHostname()

def create_workflow_summary(summary) {
    def yaml_file = workDir.resolve('workflow_summary_mqc.yaml')
    yaml_file.text  = """
    id: 'nf-core-covidhackathon-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nf-core/covidhackathon Workflow Summary'
    section_href: 'https://github.com/nf-core/covidhackathon'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
${summary.collect { k,v -> "            <dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }.join("\n")}
        </dl>
    """.stripIndent()

   return yaml_file
}

/*
 * Parse software version numbers
 */
process get_software_versions {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy',
        saveAs: { filename ->
                      if (filename.indexOf(".csv") > 0) filename
                      else null
                }

    output:
    file 'software_versions_mqc.yaml' into ch_software_versions_yaml
    file "software_versions.csv"

    script:
    // TODO nf-core: Get all tools to print their version number here
    """
    echo $workflow.manifest.version > v_pipeline.txt
    echo $workflow.nextflow.version > v_nextflow.txt
    fastqc --version > v_fastqc.txt
    multiqc --version > v_multiqc.txt
    bowtie2 --version > v_bowtie2.txt
    stringtie --version > v_stringtie.txt
    scrape_software_versions.py &> software_versions_mqc.yaml
    """
}

 /*
  * STEP 1 - FastQC
  */
 process fastqc {
     tag "$name"
     label 'process_medium'
     publishDir "${params.outdir}/fastqc", mode: 'copy',
         saveAs: { filename ->
                       filename.indexOf(".zip") > 0 ? "zips/$filename" : "$filename"
                 }

     input:
     set val(name), file(reads) from ch_read_files_fastqc

     output:
     file "*_fastqc.{zip,html}" into ch_fastqc_results

     script:
     """
     fastqc --quiet --threads $task.cpus $reads
     """
 }


/*
 * create indices
 */

fastaRef = Channel.
              fromPath('${params.fasta}/*.fa')

process createIndex {
    tag {reference}

    publishDir params.outdir, mode: params.publishDirMode,
        saveAs: {params.saveGenomeIndex ? "reference_genome/bowtie2Index/${species}/${it}" : null }

    input:
    set val(species = "${fasta.baseName}"), file(fasta) from fastaRef

    output:
    file("*bt2") into bowtie2Index

    script:
    """
    bowtie2-build $fasta $species
    """
}


refIndices = humanGenomeIdx.join(virusGenomeIdx)
/*
 * STEP 2(a) - Align across human reference genome
 */

process mapReads {

  input:
  set val(sampName), file(reads) from ch_read_files_fastqc
  set val(species), file(index) from bowtie2Index

  output:
  set sampName, species, file("*temp.bam") into alignment

  """
  bowtie2 -p -x $reads -U $genome -S ${sampName}.${species}.temp.sam
  samtools view -bS ${sampName}.${species}.temp.sam > ${sampName}.${species}.temp.bam
  """
}

// Sort bam
process sortBam{

  input:
  set sampName, species, file(tmp) from alignment

  output:
  file("${sampName}"."${species}".bam) into bamSort

  """
  samtools sort -o "${sampName}"."${species}".bam $tmp
  """
}

// Index bam
process indexBams {

  publishDir "results/alignments", mode: 'copy'

  input:
  set sampNames, species, file(bam) from bamsort

  output:
  file("${bam}.bai") into bamsidx
  file("${bam}") into bamsout

  """
  samtools index -b $bam
  """
}

/*
 * Step 3 : Identify common reads mapped to both viral and human reference genome
 *
 * The branch operator allows you to forward the items emitted by a source
 * channel to one or more output channels, choosing one out of them at a time.
 *
 * The selection criteria is defined by specifying a closure that provides one
 * or more boolean expression, each of which is identified by a unique label.
 * On the first expression that evaluates to a true value, the current item is
 * bound to a named channel as the label identifier. For example:
 *
 * Channel
 *    .from(1,2,3,40,50)
 *    .branch {
 *        small: it < 10
 *        large: it > 10
 *    }
 *    .set { result }
 *  result.small.view { "$it is small" }
 *  result.large.view { "$it is large" }
 *
 * it shows
 * 1 is small
 * 2 is small
 * 3 is small
 * 40 is large
 * 50 is large
 *
 */

Channel
    .from(bamsOut)
    .branch {
        virus: it.filter(~/*SARS_COV.*/)
        human: it.filter(~/*hg38.*/)
        }
    .set{bams}

// bams = Channel.fromFilePairs("${params.alignmentPath}/*{hg38,${params.virus}}.bam", flat: true)

process makeSharedList {

  input:
  set val(sampName), val(species), file(humanBam), from bams.human
  set val(sampName), val(species), file(virusBam), from bams.virus

  output:
  file("shared.list") into sharedList
  set val(sampName), file("human.list") into humanList
  set val(sampName), file("virus.list") into virusList

  """
  samtools view -F4 "${humanBam}" | awk '{print $1}' | sort | uniq > human.list
  samtools view -F4 "${virusBam}" | awk '{print $1}' | sort | uniq > virus.list
  cat human.list virus.list | sort | uniq -c | sort -nr | awk '{if($1==2) {print $2}}' > shared.list
  """
}

process filterHuman {

  input:
  file(sharedReads) from sharedList
  set sampName, file(human) from humanList

  output:
  file("${sampName}"."_human.uniq.bam") into humanFinal

  """
  picard FilterSamReads I=$human O="${sampName}""_human.uniq.bam" READ_LIST_FILE=$sharedReads FILTER=excludeReadList SORT_ORDER=coordinate
  """
}

process filterVirus {

  input:
  file(sharedReads) from shareList
  set sampName, file(virus) from virusList

  output:
  file("${sampName}_virus.uniq.bam") into virusFinal

  """
  picard FilterSamReads I=$virus O="${sampName}_virus.uniq.bam" READ_LIST_FILE=$sharedReads FILTER=excludeReadList SORT_ORDER=coordinate
  """
}


/*
 * Step 4 : Generate gene counts for human and virus reads(unshared)
 */
 
 // First run of StringTie to generate gene counts
 process geneCountHuman {
  
  refGtf = hgtf.join(vgtf)
  
  input:
  set sampID, file(bam) from humanFinal
  file(gtf) from refGtf
  
  output:
  file("${sampID}_human_transcripts.gtf") into humanCounts
  file("${sampID}_human_gene_abun.tab") into humanCounts
  
  """
  stringtie "${sampID}_human.uniq.bam" -o "${sampID}_human_transcripts.gtf" -G $gtf -A "${sampID}_human_gene_abun.tab"
  """
 } 
  
 process geneCountVirus {
  
  refGtf = hgtf.join(vgtf)
  
  input:
  set sampID, file(bam) from virusFinal
  file(gtf) from refGtf
  
  output:
  file("${sampID}_virus_transcripts.gtf") into virusCounts
  file("${sampID}_virus_gene_abun.tab") into virusCounts
  
  """
  stringtie "${sampID}_virus.uniq.bam" -o "${sampID}_virus_transcripts.gtf" -G $gtf -A "${sampID}_virus_gene_abun.tab"
  """
 } 

 // generating unified transcriptome.
process humanTrancriptome {
 
 input:
 set sampID, file(gtf) from humanCounts 
 file(gtf) from refGtf
 
 output:
 file('stringtie_merged_transcripts.gtf') into humanTranscriptome
 file('assembly_GTF_list.txt') into humanTranscriptome
 
 """
 stringtie --merge -o stringtie_merged_transcripts.gtf -G $gtf assembly_GTF_list.txt
 """
} 

process virusTrancriptome {
 
 input:
 set sampID, file(gtf) from virusCounts 
 file(gtf) from refGtf
 
 output:
 file('stringtie_merged_transcripts.gtf') into virusTranscriptome
 file('assembly_GTF_list.txt') into virusTranscriptome
 
 """
 stringtie --merge -o stringtie_merged_transcripts.gtf -G $gtf assembly_GTF_list.txt
 """
}

// Re-running stringtie on all samples, using merged gtf as reference genome(-g)

process humanGeneAbundance {

 input:
 set sampID, file(bam) from humanFinal
 file('stringtie_merged_transcripts.gtf') from humanTranscriptome
 
 output:
 file("${sampID}_human_transcripts.gtf") into finalHumanCounts
 file("${sampID}_human_gene_abun.tab") into finalHumanCounts
 
 """
 stringtie "${sampID}_human.uniq.bam" -o "${sampID}_human_transcripts_filtered.gtf" -eB -G "${sampID}_human_transcripts.gtf" -A "${sampID}_human_gene_abun.tab"
 """
 
 process virusGeneAbundance {

 input:
 set sampID, file(bam) from virusFinal
 file('stringtie_merged_transcripts.gtf') from virusTranscriptome
 
 output:
 file("${sampID}_virus_transcripts.gtf") into finalVirusCounts
 file("${sampID}_virus_gene_abun.tab") into finalVirusCounts
 
 """
 stringtie "${sampID}_virus.uniq.bam" -o "${sampID}_virus_transcripts_filtered.gtf" -eB -G "${sampID}_virus_transcripts.gtf" -A "${sampID}_virus_gene_abun.tab"
 """
}

/*
 * STEP 2 - MultiQC
 */
process multiqc {
    publishDir "${params.outdir}/MultiQC", mode: 'copy'

    input:
    file multiqc_config from ch_multiqc_config
    // TODO nf-core: Add in log files from your new processes for MultiQC to find!
    file ('fastqc/*') from ch_fastqc_results.collect().ifEmpty([])
    file ('software_versions/*') from ch_software_versions_yaml.collect()
    file workflow_summary from create_workflow_summary(summary)

    output:
    file "*multiqc_report.html" into ch_multiqc_report
    file "*_data"
    file "multiqc_plots"

    script:
    rtitle = custom_runName ? "--title \"$custom_runName\"" : ''
    rfilename = custom_runName ? "--filename " + custom_runName.replaceAll('\\W','_').replaceAll('_+','_') + "_multiqc_report" : ''
    // TODO nf-core: Specify which MultiQC modules to use with -m for a faster run time
    """
    multiqc -f $rtitle $rfilename --config $multiqc_config .
    """
}

/*
 * STEP 3 - Output Description HTML
 */
process output_documentation {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy'

    input:
    file output_docs from ch_output_docs

    output:
    file "results_description.html"

    script:
    """
    markdown_to_html.r $output_docs results_description.html
    """
}

/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nf-core/covidhackathon] Successful: $workflow.runName"
    if (!workflow.success) {
        subject = "[nf-core/covidhackathon] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if (workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if (workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if (workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // TODO nf-core: If not using MultiQC, strip out this code (including params.max_multiqc_email_size)
    // On success try attach the multiqc report
    def mqc_report = null
    try {
        if (workflow.success) {
            mqc_report = ch_multiqc_report.getVal()
            if (mqc_report.getClass() == ArrayList) {
                log.warn "[nf-core/covidhackathon] Found multiple reports from process 'multiqc', will use only one"
                mqc_report = mqc_report[0]
            }
        }
    } catch (all) {
        log.warn "[nf-core/covidhackathon] Could not attach MultiQC report to summary email"
    }

    // Check if we are only sending emails on failure
    email_address = params.email
    if (!params.email && params.email_on_fail && !workflow.success) {
        email_address = params.email_on_fail
    }

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: email_address, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir", mqcFile: mqc_report, mqcMaxSize: params.max_multiqc_email_size.toBytes() ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (email_address) {
        try {
            if (params.plaintext_email) { throw GroovyException('Send plaintext e-mail, not HTML') }
            // Try to send HTML e-mail using sendmail
            [ 'sendmail', '-t' ].execute() << sendmail_html
            log.info "[nf-core/covidhackathon] Sent summary e-mail to $email_address (sendmail)"
        } catch (all) {
            // Catch failures and try with plaintext
            [ 'mail', '-s', subject, email_address ].execute() << email_txt
            log.info "[nf-core/covidhackathon] Sent summary e-mail to $email_address (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File("${params.outdir}/pipeline_info/")
    if (!output_d.exists()) {
        output_d.mkdirs()
    }
    def output_hf = new File(output_d, "pipeline_report.html")
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File(output_d, "pipeline_report.txt")
    output_tf.withWriter { w -> w << email_txt }

    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";

    if (workflow.stats.ignoredCount > 0 && workflow.success) {
        log.info "-${c_purple}Warning, pipeline completed, but with errored process(es) ${c_reset}-"
        log.info "-${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCount} ${c_reset}-"
        log.info "-${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCount} ${c_reset}-"
    }

    if (workflow.success) {
        log.info "-${c_purple}[nf-core/covidhackathon]${c_green} Pipeline completed successfully${c_reset}-"
    } else {
        checkHostname()
        log.info "-${c_purple}[nf-core/covidhackathon]${c_red} Pipeline completed with errors${c_reset}-"
    }

}


def nfcoreHeader() {
    // Log colors ANSI codes
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";

    return """    -${c_dim}--------------------------------------------------${c_reset}-
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  nf-core/covidhackathon v${workflow.manifest.version}${c_reset}
    -${c_dim}--------------------------------------------------${c_reset}-
    """.stripIndent()
}

def checkHostname() {
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if (params.hostnames) {
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if (hostname.contains(hname) && !workflow.profile.contains(prof)) {
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}
