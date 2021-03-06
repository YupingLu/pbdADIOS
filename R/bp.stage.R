#' @title bp.stage.read
#'
#' @description 
#' This function is used to read the variables using staging method. 
#' Current staging method used is FLEXPATH. The user can provide an function to handle
#' the data read from writing stream. If the function is not provided, the data will be
#' printed by default.
#'
#' @param adios.filename adios filename
#' @param varname variable name
#' @param FUN user defined function. If not specified, print will be the default function.
#' @param comm mpi comm
#' @param p number of processes
#' @param adios.rank comm rank
#'
#' @return variable values. If start and count are not specified, all values will be returned.
#'
#' @export
bp.stage.read <- function(adios.filename,
                          varname,
                          FUN = print,
                          comm = .pbd_env$SPMD.CT$comm,
                          p = comm.size(.pbd_env$SPMD.CT$comm),
                          adios.rank = comm.rank(.pbd_env$SPMD.CT$comm))
{ 
    # Check if varnmae is null
    if(is.null(varname))
        stop("The varname can't be empty!")

    # Calculate the number of vars
    nvars = length(varname)

    # Initialize a reading method and open a stream
    adios.read.init.method ("ADIOS_READ_METHOD_FLEXPATH", comm, "")
    fp = adios.read.open (adios.filename, 
                          "ADIOS_READ_METHOD_FLEXPATH", 
                          comm,
                          "ADIOS_LOCKMODE_NONE",
                          0.0)
    errno = 0
    while(errno != -21) { # err_end_of_stream = -21

        # Read variables and store them as list in X
        X = .Call("R_stage_read", 
                  fp,
                  as.list(varname),
                  as.integer(nvars),
                  comm.c2f(comm),
                  as.integer(p),
                  as.integer(adios.rank))

        # Pass the read values to FUN, the default FUN is print
        FUN(X)

        # Go to the next step
        adios.release.step(fp);
        adios.advance.step(fp, 0, 30)

        # Get the current error number
        errno = adios.errno()
    }
    
    adios.read.close(fp)
    adios.read.finalize.method("ADIOS_READ_METHOD_FLEXPATH")

    invisible()
}