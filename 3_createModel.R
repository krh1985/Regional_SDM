# File: 3_createModel.R
# Purpose: to create the random forest model. This includes:
# - create initial model to remove poorest performing env vars
# - validate using leave-one-out jackknifing
# - create a final model using all presence points, stratify by EO using RA
# - build partial plots of top performing env vars for metadata output

library(RSQLite)
library(ROCR)    #for ROC plots and stats
library(vcd)     #for kappa stats
library(abind)   #for collapsing the nested lists
library(foreign) #for reading dbf files
library(randomForest)

#####
## three lines need your attention. The one directly below (loc_scripts),
## about line 29 where you choose which Rdata file to use,
## and about line 40 where you choose which record to use
loc_scripts <- "K:/Reg5Modeling_Project/scripts/Regional_SDM"

source(paste(loc_scripts, "0_pathsAndSettings.R", sep = "/"))
setwd(loc_spPts)

#get a list of what's in the directory
p_fileList <- dir( pattern = "_att.dbf$")
p_fileList
#look at the output and choose which shapefile you want to run
#enter its location in the list (first = 1, second = 2, etc)
n <- 1

presFile <- p_fileList[[n]]
# get the presence points
df.in <-read.dbf(presFile)

setwd(loc_bkgPts)
bk_fileList <- dir( pattern = "_clean.dbf$")
bk_fileList
#look at the output and choose which shapefile you want to run
#enter its location in the list (first = 1, second = 2, etc)
n <- 1
bkgFile <- bk_fileList[[n]]

# absence points
df.abs <- foreign:::read.dbf(bkgFile)

#make sure we don't have any NAs
df.in <- df.in[complete.cases(df.in),]
df.abs <- df.abs[complete.cases(df.abs),]

# align data sets, QC ----
# add some fields to each
df.in <- cbind(df.in, pres=1)
df.abs$stratum <- "pseu-a"
df.abs <- cbind(df.abs, EO_ID_ST="pseu-a", 
					pres=0, RA="high", SNAME="background")

# lower case column names
names(df.in) <- tolower(names(df.in))
names(df.abs) <- tolower(names(df.abs))

# get a list of env vars from the folder used to create the raster stack
raslist <- list.files(path = loc_envVars, pattern = ".tif$")
rasnames <- gsub(".tif", "", raslist)

# are these all in the lookup database? Checking here.
db <- dbConnect(SQLite(),dbname=nm_db_file)  
op <- options("useFancyQuotes") 
options(useFancyQuotes = FALSE) #sQuote call unhappy with fancy quote, turn off
SQLquery <- paste("SELECT gridName, fullName FROM lkpEnvVars WHERE gridName in (", 
                  toString(sQuote(rasnames)),
                  "); ", sep = "")
namesInDB <- dbGetQuery(db, statement = SQLquery)
namesInDB$gridName <- tolower(namesInDB$gridName)
rasnames <- tolower(rasnames)

## this prints rasters not in the lookup database
## if blank you are good to go, otherwise figure out what's up
rasnames[!rasnames %in% namesInDB$gridName]

## this prints out the rasters that don't appear as a column name
## in df.in (meaning it wasn't used to attribute or the name is funky)
## if blank you are good to go
rasnames[!rasnames %in% names(df.in)]

# get a list of all distance-to env vars
SQLquery <- "SELECT gridName FROM lkpEnvVars WHERE distToGrid = 1;"
dtGrids <- dbGetQuery(db, statement = SQLquery)

# clean up
options(op)
dbDisconnect(db)
rm(db)

# Remove irrelevant distance-to grids ----
# check if pres points are VERY far away from any of the dist-to grids
#   (this can cause erroneous, non-biological relationships that should
#    not be driving the model. Group decision to remove.)

# get the ones we are using here
dtRas <- rasnames[rasnames %in% dtGrids$gridName]
# what's the closest distance for each?
dtRas.min <- apply(df.in[,dtRas], 2, min)
# remove those whose closest distance is greater than 10km
dtRas.sub <- dtRas.min[dtRas.min > 10000]
rasnames <- rasnames[!rasnames %in% names(dtRas.sub)]

# clean up, merge data sets -----
# this is the full list of fields, arranged appropriately
colList <- c("sname","eo_id_st","pres","stratum", "ra", rasnames)

# if colList gets modified, 
# also modify the locations for the independent and dependent variables, here
depVarCol <- 3
indVarCols <- c(6:length(colList))

#re-arrange
df.in <- df.in[,colList]
df.abs <- df.abs[,colList]

#Fire up SQLite
db <- dbConnect(SQLite(),dbname=nm_db_file)  
  
ElementNames <- as.list(c(SciName="",CommName="",Code="",Type=""))
ElementNames[1] <- as.character(df.in[1,"sname"])

# get the names used in metadata output
SQLquery <- paste("SELECT CODE FROM lkpSpecies WHERE SCIEN_NAME = '", 
	ElementNames[1],"' ;", sep="")
ElementNames[3] <- as.list(dbGetQuery(db, statement = SQLquery)[1,1])
# populate the common name field
SQLquery <- paste("SELECT COMMONNAME FROM lkpSpecies WHERE SCIEN_NAME = '", 
	ElementNames[1],"';", sep="")
ElementNames[2] <- dbGetQuery(db, statement = SQLquery)
# populate element type (A or P)
SQLquery <- paste("SELECT ELEMTYPE FROM lkpSpecies WHERE SCIEN_NAME = '", 
	ElementNames[1],"';", sep="")
ElementNames[4] <- as.list(dbGetQuery(db, statement = SQLquery)[1,1])
ElementNames

#also get correlated env var information
SQLquery <- "SELECT gridName, correlatedVarGroupings FROM lkpEnvVars WHERE correlatedVarGroupings NOT NULL;"
corrdEVs <- dbGetQuery(db, statement = SQLquery)

dbDisconnect(db)
rm(db)

# row bind the pseudo-absences with the presence points
df.abs$eo_id_st <- factor(df.abs$eo_id_st)
df.full <- rbind(df.in, df.abs)

# reset these factors
df.full$stratum <- factor(df.full$stratum)
df.full$eo_id_st <- factor(df.full$eo_id_st)
df.full$pres <- factor(df.full$pres)
df.full$ra <- factor(tolower(as.character(df.full$ra)))
df.full$sname <- factor(df.full$sname)

# make samp size groupings ----
EObyRA <- unique(df.full[,c("eo_id_st","ra")])
EObyRA$sampSize[EObyRA$ra == "very high"] <- 5
EObyRA$sampSize[EObyRA$ra == "high"] <- 4
EObyRA$sampSize[EObyRA$ra == "medium"] <- 3
EObyRA$sampSize[EObyRA$ra == "low"] <- 2
EObyRA$sampSize[EObyRA$ra == "very low"] <- 1
# set the background pts to the sum of the EO samples
EObyRA$sampSize[EObyRA$eo_id_st == "pseu-a"] <- sum(EObyRA[!EObyRA$eo_id_st == "pseu-a", "sampSize"])

# there appear to be cases where more than one 
# RA is assigned per EO. Handle it here by 
# taking max value
EObySS <- aggregate(EObyRA$sampSize, by=list(EObyRA$eo_id_st), max)
names(EObySS) <- c("eo_id_st","sampSize")

sampSizeVec <- EObySS$sampSize
names(sampSizeVec) <- as.character(EObySS$eo_id_st)


##
# tune mtry ----
# run through mtry twice
x <- tuneRF(df.full[,indVarCols],
             y=df.full[,depVarCol],
             ntreeTry = 300, stepFactor = 2, mtryStart = 6,
            strata = df.full$eo_id_st, sampsize = sampSizeVec, replace = TRUE)

newTry <- x[x[,2] == min(x[,2]),1]

y <- tuneRF(df.full[,indVarCols],
            y=df.full[,depVarCol],
            ntreeTry = 300, stepFactor = 1.5, mtryStart = max(newTry),
            strata = df.full$eo_id_st, sampsize = sampSizeVec, replace = TRUE)

mtry <- max(y[y[,2] == min(y[,2]),1])
rm(x,y)

##
# Remove the least important env vars ----
##

ntrees <- 1000
rf.find.envars <- randomForest(df.full[,indVarCols],
                        y=df.full[,depVarCol],
                        importance=TRUE,
                        ntree=ntrees,
                        mtry=mtry,
                        strata = df.full$eo_id_st, sampsize = sampSizeVec, replace = TRUE)

impvals <- importance(rf.find.envars, type = 1)
OriginalNumberOfEnvars <- length(impvals)

# first remove the bottom of the correlated vars
for(grp in unique(corrdEVs$correlatedVarGroupings)){
  vars <- tolower(corrdEVs[corrdEVs$correlatedVarGroupings == grp,"gridName"])
  imp.sub <- impvals[rownames(impvals) %in% vars,, drop = FALSE]
  varsToDrop <- imp.sub[!imp.sub == max(imp.sub),, drop = FALSE]
  impvals <- impvals[!rownames(impvals) %in% rownames(varsToDrop),,drop = FALSE]
}
rm(vars, imp.sub, varsToDrop)

# set the percentile, here choosing above 25% percentile
envarPctile <- 0.25
y <- quantile(impvals, probs = envarPctile)
impEnvVars <- impvals[impvals > y,]
subsetNumberofEnvars <- length(impEnvVars)
rm(y)
# which columns are these, then flip the non-envars to TRUE
impEnvVarCols <- names(df.full) %in% names(impEnvVars)
impEnvVarCols[1:5] <- TRUE
# subset!
df.full <- df.full[,impEnvVarCols]
# reset the indvarcols object
indVarCols <- c(6:length(names(df.full)))

##
# code above is for removing least important env vars
##

# prep for validation loop ----
#now that entire set is cleaned up, split back out to use any of the three DFs below
df.in2 <- subset(df.full,pres == "1")
df.abs2 <- subset(df.full, pres == "0")
df.in2$stratum <- factor(df.in2$stratum)
df.abs2$stratum <- factor(df.abs2$stratum)
df.in2$eo_id_st <- factor(df.in2$eo_id_st)
df.abs2$eo_id_st <- factor(df.abs2$eo_id_st)
df.in2$pres <- factor(df.in2$pres)
df.abs2$pres <- factor(df.abs2$pres)

#reset the row names, needed for random subsetting method of df.abs2, below
row.names(df.in2) <- 1:nrow(df.in2)
row.names(df.abs2) <- 1:nrow(df.abs2)

#how many polygons do we have?
numPys <-  nrow(table(df.in2$stratum))
#how many EOs do we have?
numEOs <- nrow(table(df.in2$eo_id_st))

#initialize the grouping list, and set up grouping variables
#if we have fewer than 10 EOs, move forward with jackknifing by polygon, otherwise
#jackknife by EO.
group <- vector("list")
# group$colNm <- ifelse(numEOs < 10,"stratum","eo_id_st")
# group$JackknType <- ifelse(numEOs < 10,"polygon","element occurrence")
# if(numEOs < 10) {
# 		group$vals <- unique(df.in2$stratum)
# } else {
# 		group$vals <- unique(df.in2$eo_id_st)
# }
## TODO: bring back by-polygon validation. SampSize needs to be able to handle this to make it possible
# only validate by EO at this time:
group$colNm <- "eo_id_st"
group$JackknType <- "element occurrence"
group$vals <- unique(df.in2$eo_id_st)

#reduce the number of trees if group$vals has more than 30 entries
#this is for validation
if(length(group$vals) > 30) {
	ntrees <- 750
} else {
	ntrees <- 1000
}

##initialize the Results vectors for output from the jackknife runs
trRes <- vector("list",length(group$vals))
   names(trRes) <- group$vals[]
evSet <- vector("list",length(group$vals))
   names(evSet) <- group$vals[]	   
evRes <- vector("list",length(group$vals))
   names(evRes) <- group$vals[]
t.f <- vector("list",length(group$vals))
   names(t.f) <- group$vals[]
t.ctoff <- vector("list",length(group$vals))
   names(t.ctoff) <- group$vals[]
v.rocr.rocplot <- vector("list",length(group$vals))
   names(v.rocr.rocplot) <- group$vals[]
v.rocr.auc <- vector("list",length(group$vals))
   names(v.rocr.auc) <- group$vals[]
v.y <- vector("list",length(group$vals))
   names(v.y) <- group$vals[]
v.kappa <- vector("list",length(group$vals))
   names(v.kappa) <- group$vals[]
v.tss <- vector("list",length(group$vals))
   names(v.tss) <- group$vals[]
v.OvAc <- vector("list",length(group$vals))
   names(v.OvAc) <- group$vals[]
t.importance <- vector("list",length(group$vals))
   names(t.importance) <- group$vals[]
t.rocr.pred <- vector("list",length(group$vals))
   names(t.rocr.pred) <- group$vals[]
v.rocr.pred <- vector("list",length(group$vals))
   names(v.rocr.pred) <- group$vals[]
   
#######
## This is the validation loop. ----
## it creates a model for all-but-one group (EO, polygon, or group),
## tests if it can predict that group left out,
## then moves on to another group, cycling though all groups
## Validation stats in tabular form are the final product.
#######
      
if(length(group$vals)>1){
	for(i in 1:length(group$vals)){
		   # Create an object that stores the select command, to be used by subset.
		  trSelStr <- parse(text=paste(group$colNm[1]," != '", group$vals[[i]],"'",sep=""))
		  evSelStr <- parse(text=paste(group$colNm[1]," == '", group$vals[[i]],"'",sep=""))
		   # apply the subset. do.call is needed so selStr can be evaluated correctly
		  trSet <- do.call("subset",list(df.in2, trSelStr))
		  evSet[[i]] <- do.call("subset",list(df.in2, evSelStr))
		   # use sample to grab a random subset from the background points
		  BGsampSz <- nrow(evSet[[i]])
		  evSetBG <- df.abs2[sample(nrow(df.abs2), BGsampSz , replace = FALSE, prob = NULL),]
		   # get the other portion for the training set
		  TrBGsamps <- attr(evSetBG, "row.names") #get row.names as integers
		  trSetBG <-  df.abs2[-TrBGsamps,]  #get everything that isn't in TrBGsamps
		   # join em, clean up
		  trSet <- rbind(trSet, trSetBG)
		  trSet$eo_id_st <- factor(trSet$eo_id_st)
		  evSet[[i]] <- rbind(evSet[[i]], evSetBG)
		  
		  ssVec <- sampSizeVec[!names(sampSizeVec) == group$vals[[i]]]
		  rm(trSetBG, evSetBG)
		  
		  trRes[[i]] <- randomForest(trSet[,indVarCols],y=trSet[,depVarCol],
		                             importance=TRUE,ntree=ntrees,mtry=mtry,
		                             strata = trSet[,group$colNm], sampsize = ssVec, replace = TRUE
		                             )
		  
		  # run a randomForest predict on the validation data
		  evRes[[i]] <- predict(trRes[[i]], evSet[[i]], type="prob")
		   # use ROCR to structure the data. Get pres col of evRes (= named "1")
		  v.rocr.pred[[i]] <- prediction(evRes[[i]][,"1"],evSet[[i]]$pres)
		   # extract the auc for metadata reporting
		  v.rocr.auc[[i]] <- performance(v.rocr.pred[[i]], "auc")@y.values[[1]]
			cat("finished run", i, "of", length(group$vals), "\n")
	}

	# restructure validation predictions so ROCR will average the figure
	v.rocr.pred.restruct <- v.rocr.pred[[1]]
	#send in the rest
	for(i in 2:length(v.rocr.pred)){
		v.rocr.pred.restruct@predictions[[i]] <- v.rocr.pred[[i]]@predictions[[1]]
		v.rocr.pred.restruct@labels[[i]] <- v.rocr.pred[[i]]@labels[[1]]
		v.rocr.pred.restruct@cutoffs[[i]] <- v.rocr.pred[[i]]@cutoffs[[1]]
		v.rocr.pred.restruct@fp[[i]] <- v.rocr.pred[[i]]@fp[[1]]
		v.rocr.pred.restruct@tp[[i]] <- v.rocr.pred[[i]]@tp[[1]]
		v.rocr.pred.restruct@tn[[i]] <- v.rocr.pred[[i]]@tn[[1]]
		v.rocr.pred.restruct@fn[[i]] <- v.rocr.pred[[i]]@fn[[1]]
		v.rocr.pred.restruct@n.pos[[i]] <- v.rocr.pred[[i]]@n.pos[[1]]
		v.rocr.pred.restruct@n.neg[[i]] <- v.rocr.pred[[i]]@n.neg[[1]]
		v.rocr.pred.restruct@n.pos.pred[[i]] <- v.rocr.pred[[i]]@n.pos.pred[[1]]
		v.rocr.pred.restruct@n.neg.pred[[i]] <- v.rocr.pred[[i]]@n.neg.pred[[1]]
	}

	# run a ROC performance with ROCR
	v.rocr.rocplot.restruct <- performance(v.rocr.pred.restruct, "tpr","fpr")
	# send it to perf for the averaging lines that follow
	perf <- v.rocr.rocplot.restruct

	## for infinite cutoff, assign maximal finite cutoff + mean difference
	## between adjacent cutoff pairs  (this code is from ROCR)
	if (length(perf@alpha.values)!=0) perf@alpha.values <-
		lapply(perf@alpha.values,
			function(x) { isfin <- is.finite(x);
				x[is.infinite(x)] <-
					(max(x[isfin]) +
						mean(abs(x[isfin][-1] -
						x[isfin][-length(x[isfin])])));
				x[is.nan(x)] <- 0.001; #added by tgh to handle vectors length 2
		x})

	for (i in 1:length(perf@x.values)) {
		ind.bool <- (is.finite(perf@x.values[[i]]) & is.finite(perf@y.values[[i]]))
		if (length(perf@alpha.values) > 0)
			perf@alpha.values[[i]] <- perf@alpha.values[[i]][ind.bool]
		perf@x.values[[i]] <- perf@x.values[[i]][ind.bool]
		perf@y.values[[i]] <- perf@y.values[[i]][ind.bool]
	}
	perf.sampled <- perf

	# create a list of cutoffs to interpolate off of
	alpha.values <- rev(seq(min(unlist(perf@alpha.values)),
							max(unlist(perf@alpha.values)),
							length=max(sapply(perf@alpha.values, length))))
	# interpolate by cutoff, values for y and x
	for (i in 1:length(perf.sampled@y.values)) {
		perf.sampled@x.values[[i]] <-
		  approxfun(perf@alpha.values[[i]],perf@x.values[[i]],
					rule=2, ties=mean)(alpha.values)
		perf.sampled@y.values[[i]] <-
		  approxfun(perf@alpha.values[[i]], perf@y.values[[i]],
					rule=2, ties=mean)(alpha.values)
	}

	## compute average curve
	perf.avg <- perf.sampled
	perf.avg@x.values <- list(rowMeans( data.frame( perf.avg@x.values)))
	perf.avg@y.values <- list(rowMeans( data.frame( perf.avg@y.values)))
	perf.avg@alpha.values <- list( alpha.values )

	# find the best cutoff based on the averaged ROC curve
	### TODO: customize/calculate this for each model rather than
	### average? 
	cutpt <- which.max(abs(perf.avg@x.values[[1]]-perf.avg@y.values[[1]]))
	cutval <- perf.avg@alpha.values[[1]][cutpt]
	cutX <- perf.avg@x.values[[1]][cutpt]
	cutY <- perf.avg@y.values[[1]][cutpt]
	cutval.rf <- c(1-cutval,cutval)
	names(cutval.rf) <- c("0","1")

	for(i in 1:length(group$vals)){
		#apply the cutoff to the validation data
		v.rf.pred.cut <- predict(trRes[[i]], evSet[[i]],type="response", cutoff=cutval.rf)
		#make the confusion matrix
		v.y[[i]] <- table(observed = evSet[[i]][,"pres"],
			predicted = v.rf.pred.cut)
		#add estimated accuracy measures
		v.y[[i]] <- cbind(v.y[[i]],
			"accuracy" = c(v.y[[i]][1,1]/sum(v.y[[i]][1,]), v.y[[i]][2,2]/sum(v.y[[i]][2,])))
		#add row, col names
		rownames(v.y[[i]])[rownames(v.y[[i]]) == "0"] <- "background/abs"
		rownames(v.y[[i]])[rownames(v.y[[i]]) == "1"] <- "known pres"
		colnames(v.y[[i]])[colnames(v.y[[i]]) == "0"] <- "pred. abs"
		colnames(v.y[[i]])[colnames(v.y[[i]]) == "1"] <- "pred. pres"
		print(v.y[[i]])
		#Generate kappa statistics for the confusion matrices
		v.kappa[[i]] <- Kappa(v.y[[i]][1:2,1:2])
		#True Skill Statistic
		v.tss[[i]] <- v.y[[i]][2,3] + v.y[[i]][1,3] - 1
		#Overall Accuracy
		v.OvAc[[i]] <- (v.y[[i]][[1,1]]+v.y[[i]][[2,2]])/sum(v.y[[i]][,1:2])
		### importance measures ###
		#count the number of variables
		n.var <- nrow(trRes[[i]]$importance)
		#get the importance measures (don't get GINI coeff - see Strobl et al. 2006)
		imp <- importance(trRes[[i]], class = NULL, scale = TRUE, type = NULL)
		imp <- imp[,"MeanDecreaseAccuracy"]
		#get number of variables used in each forest
		used <- varUsed(trRes[[i]])
		names(used) <- names(imp)
		t.importance[[i]] <- data.frame("meanDecreaseAcc" = imp,
									"timesUsed" = used )
	} #close loop

	#housecleaning
	rm(trSet, evSet)

	#average relevant validation/summary stats
	# Kappa - wieghted, then unweighted
	K.w <- unlist(v.kappa, recursive=TRUE)[grep("Weighted.value",
						names(unlist(v.kappa, recursive=TRUE)))]
	Kappa.w.summ <- data.frame("mean"=mean(K.w), "sd"=sd(K.w),"sem"= sd(K.w)/sqrt(length(K.w)))
	K.unw <- unlist(v.kappa, recursive=TRUE)[grep("Unweighted.value",
						names(unlist(v.kappa, recursive=TRUE)))]
	Kappa.unw.summ <- data.frame("mean"=mean(K.unw), "sd"=sd(K.unw),"sem"= sd(K.unw)/sqrt(length(K.unw)))
	#AUC - area under the curve
	auc <- unlist(v.rocr.auc)
	auc.summ <- data.frame("mean"=mean(auc), "sd"=sd(auc),"sem"= sd(auc)/sqrt(length(auc)))
	#TSS - True skill statistic
	tss <- unlist(v.tss) 
	tss.summ <- data.frame("mean"=mean(tss), "sd"=sd(tss),"sem"= sd(tss)/sqrt(length(tss)))
	#Overall Accuracy
	OvAc <- unlist(v.OvAc)
	OvAc.summ <- data.frame("mean"=mean(OvAc), "sd"=sd(OvAc),"sem"= sd(OvAc)/sqrt(length(OvAc)))
	#Specificity and Sensitivity
	v.y.flat <- abind(v.y,along=1)  #collapsed confusion matrices
	v.y.flat.sp <- v.y.flat[rownames(v.y.flat)=="background/abs",]
	v.y.flat.sp <- as.data.frame(v.y.flat.sp, row.names = 1:length(v.y.flat.sp[,1]))
	specif <- v.y.flat.sp[,"pred. abs"]/(v.y.flat.sp[,"pred. abs"] + v.y.flat.sp[,"pred. pres"])   #specificity
	specif.summ <- data.frame("mean"=mean(specif), "sd"=sd(specif),"sem"= sd(specif)/sqrt(length(specif)))
	v.y.flat.sn <- v.y.flat[rownames(v.y.flat)=="known pres",]
	v.y.flat.sn <- as.data.frame(v.y.flat.sn, row.names = 1:length(v.y.flat.sn[,1]))
	sensit <- v.y.flat.sn[,"pred. pres"]/(v.y.flat.sn[,"pred. pres"] + v.y.flat.sn[,"pred. abs"])    #sensitivity
	sensit.summ <- data.frame("mean"=mean(sensit), "sd"=sd(sensit),"sem"= sd(sensit)/sqrt(length(sensit)))

	summ.table <- data.frame(Name=c("Weighted Kappa", "Unweighted Kappa", "AUC",
									"TSS", "Overall Accuracy", "Specificity",
									"Sensitivity"),
							 Mean=c(Kappa.w.summ$mean, Kappa.unw.summ$mean,auc.summ$mean,
									tss.summ$mean, OvAc.summ$mean, specif.summ$mean,
									sensit.summ$mean),
							 SD=c(Kappa.w.summ$sd, Kappa.unw.summ$sd,auc.summ$sd,
									tss.summ$sd, OvAc.summ$sd, specif.summ$sd,
									sensit.summ$sd),
							 SEM=c(Kappa.w.summ$sem, Kappa.unw.summ$sem,auc.summ$sem,
									tss.summ$sem, OvAc.summ$sem, specif.summ$sem,
									sensit.summ$sem))
	summ.table
} else {
	cat("Only one polygon, can't do validation", "\n")
	cutval <- NA
}

# increase the number of trees for the full model
ntrees <- 2000
   
####
#   run the full model ----
####

rf.full <- randomForest(df.full[,indVarCols],
                        y=df.full[,depVarCol],
                        importance=TRUE,
                        ntree=ntrees,
                        mtry=mtry,
                        strata = df.full[,"eo_id_st"],
                        sampsize = sampSizeVec, replace = TRUE,
                        norm.votes = TRUE)

####
# Importance measures ----
####
#get the importance measures (don't get GINI coeff - see Strobl et al. 2006)
f.imp <- importance(rf.full, class = NULL, scale = TRUE, type = NULL)
f.imp <- f.imp[,"MeanDecreaseAccuracy"]

db <- dbConnect(SQLite(),dbname=nm_db_file)  
# get importance data, set up a data frame
EnvVars <- data.frame(gridName = names(f.imp), impVal = f.imp, fullName="", stringsAsFactors = FALSE)
#set the query for the following lookup, note it builds many queries, equal to the number of vars
SQLquery <- paste("SELECT gridName, fullName FROM lkpEnvVars WHERE gridName COLLATE NOCASE in ('", paste(EnvVars$gridName,sep=", "),
					"'); ", sep="")
#cycle through all select statements, put the results in the df
for(i in 1:length(EnvVars$gridName)){
  EnvVars$fullName[i] <- as.character(dbGetQuery(db, statement = SQLquery[i])[,2])
  }
##clean up
dbDisconnect(db)

###
# partial plot data ----
###
#get the order for the importance charts
ord <- order(EnvVars$impVal, decreasing = TRUE)[1:length(indVarCols)]
#set up a list to hold the plot data
pPlots <- vector("list",9)
		names(pPlots) <- c(1:9)
#get the top eight partial plots
for(i in 1:9){
	pPlots[[i]] <- partialPlot(rf.full, df.full[,indVarCols],
						names(f.imp[ord[i]]),
						which.class = 1,
						plot = FALSE)
	pPlots[[i]]$gridName <- names(f.imp[ord[i]])
	pPlots[[i]]$fname <- EnvVars$fullName[ord[i]]
	cat("finished partial plot ", i, " of 9", "\n")
	}

#save the project, return to the original working directory
setwd(loc_RDataOut)
save.image(file = paste(ElementNames$Code, "_",Sys.Date(),".Rdata", sep=""))

## clean up ----
# remove all objects before moving on to the next script
rm(list=ls())
