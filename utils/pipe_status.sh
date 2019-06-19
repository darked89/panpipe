# *- bash -*

# INCLUDE BASH LIBRARY
. ${panpipe_bindir}/panpipe_lib || exit 1

########
print_desc()
{
    echo "pipe_status get status of pipeline steps"
    echo "type \"pipe_status --help\" to get usage information"
}

########
usage()
{
    echo "pipe_status               -d <string> [-s <string>]"
    echo "                          [--help]"
    echo ""
    echo "-d <string>               Directory where the pipeline steps are stored"
    echo "-s <string>               Step name whose status should be determined"
    echo "-i                        Show scheduler ids for pipeline steps"
    echo "--help                    Display this help and exit"
}

########
read_pars()
{
    d_given=0
    s_given=0
    i_given=0
    while [ $# -ne 0 ]; do
        case $1 in
            "--help") usage
                      exit 1
                      ;;
            "-d") shift
                  if [ $# -ne 0 ]; then
                      pdir=$1
                      d_given=1
                  fi
                  ;;
            "-s") shift
                  if [ $# -ne 0 ]; then
                      given_stepname=$1
                      s_given=1
                  fi
                  ;;
            "-i") if [ $# -ne 0 ]; then
                      i_given=1
                  fi
                  ;;
        esac
        shift
    done   
}

########
check_pars()
{
    if [ ${d_given} -eq 0 ]; then
        echo "Error! -d parameter not given!" >&2
        exit 1
    else
        if [ ! -d ${pdir} ]; then
            echo "Error! pipeline directory does not exist" >&2 
            exit 1
        fi

        if [ ! -f ${pdir}/command_line.sh ]; then
            echo "Error! ${pdir}/command_line.sh file is missing" >&2 
            exit 1
        fi
    fi
}

########
get_orig_workdir()
{
    local command_line_file=$1
    local workdir=`$HEAD -1 ${command_line_file} | $AWK '{print $2}'` ; pipe_fail || return 1
    echo $workdir
}

########
get_orig_outdir()
{
    # initialize variables
    local command_line_file=$1

    # Extract information from command line file
    local workdir=`$HEAD -1 ${command_line_file} | $AWK '{print $2}'` ; pipe_fail || return 1
    local cmdline=`$TAIL -1 ${command_line_file}` || return 1
    local outdir=`read_opt_value_from_line "$cmdline" "--outdir"`

    # Retrieve original output directory
    local oldpwd=$PWD
    cd $workdir
    local outdir_abspath=`get_absolute_path ${outdir}` || { cd $oldpwd; return 1; }
    cd $oldpwd

    # Print result
    echo ${outdir_abspath}
}

########
get_cmdline()
{
    local command_line_file=$1
    local cmdline=`$TAIL -1 ${command_line_file}`
    echo $cmdline
}

########
get_pfile()
{
    local command_line_file=$1
    local cmdline=`$TAIL -1 ${command_line_file}`
    local pfile=`read_opt_value_from_line "$cmdline" "--pfile"` || return 1
    echo $pfile
}

########
get_sched()
{
    local command_line_file=$1
    local cmdline=`$TAIL -1 ${command_line_file}`
    local sched=`read_opt_value_from_line "$cmdline" "--sched"` || return 1
    echo $sched
}

########
replace_outdir_in_cmdline()
{
    local cmdline=$1
    local newdir=$2

    echo $cmdline | $AWK -v newdir=$newdir 'BEGIN{
                                replace=0
                               }
                               {
                                for(i=1;i<=NF;++i)
                                {
                                 if(replace==0)
                                 {
                                  printf"%s",$i
                                 } 
                                 else
                                 {
                                  printf"%s",newdir
                                  replace=0
                                 }
                                 if($i=="--outdir") replace=1
                                 if(i!=NF) printf" "
                                }
                               }'
}

########
configure_scheduler()
{
    local sched=$1
    if [ ${sched} != ${OPT_NOT_FOUND} ]; then
        set_panpipe_scheduler ${sched} || return 1
    fi
}

########
process_status_for_pfile()
{
    local dirname=$1
    local absdirname=`get_absolute_path ${dirname}`
    local command_line_file=${absdirname}/command_line.sh
    
    # Extract information from command_line.sh file
    local orig_workdir=`get_orig_workdir ${command_line_file}` || return 1
    local cmdline=`get_cmdline ${command_line_file}` || return 1
    local pfile=`get_pfile ${command_line_file}` || return 1
    local sched=`get_sched ${command_line_file}` || return 1

    # Change directory
    cd ${orig_workdir}
    
    # Get original output directory
    local orig_outdir=`get_orig_outdir ${command_line_file}`

    # Show warning if directory provided as option is different than the
    # original working directory
    if [ ${orig_outdir} = ${absdirname} ]; then
        local moved_outdir="no"        
    else
        echo "Warning: pipeline output directory was moved (original directory: ${orig_outdir})" >&2
        cmdline=`replace_outdir_in_cmdline "${cmdline}" ${absdirname}`
        local moved_outdir="yes"
    fi

    # Load pipeline modules
    load_pipeline_modules $pfile || return 1

    # Configure scheduler
    configure_scheduler $sched || return 1
    
    # Read information about the steps to be executed
    lineno=1
    num_steps=0
    num_finished=0
    num_inprogress=0
    num_unfinished=0
    num_unfinished_but_runnable=0
    num_todo=0
    while read stepspec; do
        local stepspec_comment=`pipeline_stepspec_is_comment "$stepspec"`
        local stepspec_ok=`pipeline_stepspec_is_ok "$stepspec"`
        if [ ${stepspec_comment} = "no" -a ${stepspec_ok} = "yes" ]; then
            # Increase number of steps
            num_steps=$((num_steps + 1))
            
            # Extract step information
            local stepname=`extract_stepname_from_stepspec "$stepspec"`

            # If s option was given, continue to next iteration if step
            # name does not match with the given one
            if [ ${s_given} -eq 1 -a "${given_stepname}" != $stepname ]; then
                continue
            fi

            # Check step status
            local status=`get_step_status ${absdirname} ${stepname}`

            # Obtain ids if requested
            local ids_info
            if [ ${i_given} -eq 1 ]; then
                ids_info=`read_ids_from_files ${absdirname} ${stepname}`
            fi
            
            # Print status
            if [ ${i_given} -eq 0 ]; then
                echo "STEP: $stepname ; STATUS: $status"
            else
                echo "STEP: $stepname ; STATUS: $status ; SCHED_IDS: ${ids_info}"
            fi

            # Treat step status
            case $status in
                ${FINISHED_STEP_STATUS}) num_finished=$((num_finished + 1))
                                         ;;
                ${INPROGRESS_STEP_STATUS}) num_inprogress=$((num_inprogress + 1))
                                           ;;
                ${UNFINISHED_STEP_STATUS}) num_unfinished=$((num_unfinished + 1))
                                           ;;
                ${UNFINISHED_BUT_RUNNABLE_STEP_STATUS}) num_unfinished_but_runnable=$((num_unfinished_but_runnable + 1))
                                                        ;;
                ${TODO_STEP_STATUS}) num_todo=$((num_todo + 1))
                                     ;;
            esac
                        
        else
            if [ ${stepspec_comment} = "no" -a ${stepspec_ok} = "no" ]; then
                echo "Error: incorrect step specification at line $lineno of ${pfile}" >&2
                return 1
            fi
        fi
        
        # Increase lineno
        lineno=$((lineno+1))
        
    done < ${pfile}

    # Print summary
    echo "* SUMMARY: num_steps= ${num_steps} ; finished= ${num_finished} ; inprogress= ${num_inprogress} ; unfinished= ${num_unfinished} ; unfinished_but_runnable= ${num_unfinished_but_runnable} ; todo= ${num_todo}" >&2
    
    # Return error if pipeline is not finished
    if [ ${num_finished} -eq ${num_steps} ]; then
        return ${PIPELINE_FINISHED_EXIT_CODE}
    else
        if [ ${num_inprogress} -gt 0 ]; then
            return ${PIPELINE_IN_PROGRESS_EXIT_CODE}
        else
            return ${PIPELINE_UNFINISHED_EXIT_CODE}
        fi
    fi
}

########

if [ $# -eq 0 ]; then
    print_desc
    exit 1
fi

read_pars $@ || exit 1

check_pars || exit 1

process_status_for_pfile ${pdir} ${pfile}

exit $?
