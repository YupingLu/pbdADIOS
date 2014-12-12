library(pbdMPI, quiet = TRUE)
library(pbdDMAT, quiet = TRUE)
library(pbdADIOS, quiet = TRUE)
library(raster, quiet=TRUE)
library(ggplot2, quiet=TRUE)
library(grid, quiet=TRUE)

## begin function definitions
adios.init <- function(method="ADIOS_READ_METHOD_BP", par="verbose=3")
{
    invisible(adios.read.init.method("ADIOS_READ_METHOD_BP",
                                     params="verbose=3"))
}

adios.open <- function(file, timeout=1, method="ADIOS_READ_METHOD_BP",
                       lockmode="ADIOS_LOCKMODE_NONE")
{
    ## timeout default is 1 sec
    pt <- adios.read.open(file, adios.timeout=timeout, "ADIOS_READ_METHOD_BP",
                          adios.lockmode="ADIOS_LOCKMODE_NONE")
    if(comm.rank() == 0) bpls <- system(paste("bpls", file), intern=TRUE)
    else bpls <- NULL
    bpls <- bcast(bpls)
    list(pt=pt, bpls=bpls)
}

raster_plot <- function(x, nrow, ncol, basename="raster", sequence=1, swidth=3)
{
    x <- data.frame(rasterToPoints(raster(matrix(x, nrow, ncol),
                                          xmn=0, xmx=ncol, ymn=0, ymx=nrow)))
    names(x) <- c("x", "y", basename)
    png(paste(basename, "_", formatC(sequence, width=swidth, flag=0), "_",
              comm.rank(), ".png", sep=""))
    print(ggplot(x, aes_string(x="x", y="y", fill=basename)) + geom_raster() +
          theme_minimal() + theme(axis.text.x=element_blank(),
                                  axis.ticks.x=element_blank(),
                                  axis.title.x=element_blank(),
                                  legend.position="none",
                                  plot.margin=unit(c(0,0,0,0),"cm")
                                  )
          )
    dev.off()
}
## end function definitions

init.grid()
adios.init()

## specify and open file for reading
dir.data <- "/lustre/atlas/scratch/ost/stf006/heat"
file <- paste(dir.data, "heat.bp", sep="/")
file.ptr <- adios.open(file)

## select variable to read
variable <- "T"

## get variable dimensions
varinfo = adios.inq.var(file.ptr$pt, variable)
block <- adios.inq.var.blockinfo(file.ptr$pt, varinfo)
ndim <- custom.inq.var.ndim(varinfo)
dims <- custom.inq.var.dims(varinfo)

## get dimensions and split
source("pbdADIOS/tests/partition.r")
g.dim <- dims
split <- c(TRUE, FALSE)
my.data.partition <- data.partition(seq(0, 0, along.with=g.dim), g.dim, split)
my.dim <- my.count <- my.data.partition$my.dim
my.start <- my.data.partition$my.start
my.grid <- my.data.partition$my.grid

## partition across first dimension (expects at least 2d)
slice_size0 <- as.integer(dims[1] %/% comm.size())
slice_size <- slice_size0
if(comm.rank() == (comm.size() - 1))
    slice_size <- as.integer(slice_size + (dims[1] %% comm.size()))
start <- c(as.integer(comm.rank() * slice_size0), rep(0, ndim - 1))
count <- c(slice_size, as.integer(dims[2:ndim]))

errno <- 0 # Default value 0
steps <- 0
retval <- 0
bufsize <- 10
buffer <- matrix(NA, ncol=prod(my.count), nrow=bufsize)
a0 <- matrix(NA, ncol=prod(my.count), nrow=bufsize)
a1 <- matrix(NA, ncol=prod(my.count), nrow=bufsize)
a2 <- matrix(NA, ncol=prod(my.count), nrow=bufsize)
rhs <- cbind(rep(1, bufsize), poly(1:bufsize, degree=2))

while(errno != -21) { ## This is hard-coded for now. -21=err_end_of_stream
    steps = steps + 1 ## Double check with Norbert. Should it start with 1 or 2

    ## set reading bounding box
    adios.selection  <- adios.selection.boundingbox(ndim, my.start, my.count)
    comm.print("Selection.boundingbox complete ...")
    
    ## schedule the read
    adios.data <- adios.schedule.read(varinfo, my.start, my.count, file.ptr$pt,
                                      adios.selection, variable, 0, 1)
    comm.print("Schedule read complete ...")
    
    ## perform the read
    adios.perform.reads(file.ptr$pt, 1)
    comm.print("Perform read complete ...")

    data_chunk <- custom.data.access(adios.data, adios.selection, varinfo)
    comm.print("Data access complete ...")

    ## print a few to verify
    comm.cat("first 5:", head(data_chunk, 5),"\n")
    comm.cat("last 5:", tail(data_chunk, 5),"\n")

    ## shape into matrix with first dim as rows
    ## local reshape dimensions
    my.ncol <- prod(my.dim[2])
    my.nrow <- my.dim[1]
    ldim <- c(my.nrow, my.ncol)

    ## global reshape dimensions
    g.ncol <- prod(g.dim[2])
    g.nrow <- g.dim[1]
    gdim <- c(g.nrow, g.ncol)
    
    ## now glue into a ddmatrix
    ##  x <- matrix(data_chunk, nrow=my.nrow, ncol=my.ncol, byrow=FALSE)
    ##  X <- new("ddmatrix", Data=x, dim=gdim, ldim=ldim, bldim=ldim, ICTXT=2)

    ## Fit a quadratic to a moving window of 10 steps
    ## Actually don't need the ddmatrix for this and can go straight
    ## from data_chunk into buffer matrix
    buffer <- rbind(buffer[-1, ], data_chunk)

    ## plot the original local matrix (swapping row to col - C to R)
    raster_plot(data_chunk, my.ncol, my.nrow, "T", steps)
    
    if(steps >= bufsize)
        {
            fit <- lm.fit(rhs, buffer)$coefficients
            raster_plot(fit[1, ], my.ncol, my.nrow, "a0", steps)
            raster_plot(fit[2, ], my.ncol, my.nrow, "a1", steps)
            raster_plot(fit[3, ], my.ncol, my.nrow, "a2", steps)
        }
    
    ## All these work fine!
    ##    X <- as.blockcyclic(X, bldim=c(4, 4))
    ##    X.pc <- prcomp(X)
    ##    comm.print(X.pc)
    
    s <- sum(data_chunk)
    n <- length(data_chunk)
    sa <- allreduce(s)
    na <- allreduce(n)
    comm.cat(comm.rank(), "mean =", sa/na, "lmean =", s/n, "ln =", n, "\n",
             quiet=TRUE, all.rank=TRUE)

    ##
    ## Here, write out the results of the analysis
    ## For testing purposes, write the data.chunk back.
    ##
    
    ## try to get more data
    adios.advance.step(file.ptr$pt, 0, adios.timeout.sec=1)
    comm.print(paste("Done advance.step", steps, "..."))
     
    ## check errors
    errno <- adios.errno()
    comm.cat("Error Num",errno, "\n")

    ## if error is timeout (or EOF)
    if(errno == -22){ #-22 = err_step_notready
        comm.cat(comm.rank(), "Timeout waiting for more data. Quitting ...\n")
        break
    }
if(steps > 20) break
} # While end 

comm.print("Broke out of loop ...")
adios.read.close(file.ptr$pt)
comm.print("File closed")
adios.read.finalize.method("ADIOS_READ_METHOD_BP")
comm.print("Finalized adios ...")
finalize() # pbdMPI finalize
