#!/usr/bin/perl -w

#Copyright (c) 2012, Stargazy Studios
#All Rights Reserved

# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#     * Redistributions of source code must retain the above copyright
#       notice, this list of conditions and the following disclaimer.
#     * Redistributions in binary form must reproduce the above copyright
#       notice, this list of conditions and the following disclaimer in the
#       documentation and/or other materials provided with the distribution.
#     * Neither the name of Stargazy Studios nor the
#       names of its contributors may be used to endorse or promote products
#       derived from this software without specific prior written permission.
# 
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER BE LIABLE FOR ANY
# DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#xmlToHeader will search an input XSD file for ComplexTypes containing Processing 
#Instructions with a target the same as a specified keyword (default 'uidGenerator'). 
#Elements of this ComplexType will be checked for in an input XML file. Those found will 
#have a specified child Element's text value paired with an enumeration in a C header file
# (by default a header file is generated per ComplexType). The text value of the specified
# Element must be filtered to ensure that it's unique, and only contain valid 
#characters for an enumeration name. The enumeration constitutes a (name,uid) pair.

#It is possible to manually set an Element's uid in an attribute. These take 
#precedence over automatically generated uids, and collisions between manually set uids 
#are caught. Gaps in the enumeration, caused by manually set uids not being continuous are
# also catered for when outputting the header file.

#Processing Instruction optional parameters:
#	syntax: name=[value[|alt_value]*]
#		prepName=["ComplexType"]: 	Prepend string to all enumeration names.
#											-ComplexType: use type name of the Element.
#		prepCase=["snakeUpper"]:	Set the case of preposition.
#											-snakeUpper: all upper case, with snake 
#											formatted spacing.
#		scope=["global"]: 			Used to group Elements into different header files, 
#									depending on the scope specified.
#											-global: group all Elements in the whole 
#											document of a single ComplexType.

#TODO: implement different scope and other PI options.
 
use strict;
use Getopt::Long;
use XML::LibXML;
use String::CamelCase qw(camelize decamelize wordsplit);
use Data::Dumper;
										
sub checkTypeAndExpandElement{
	my ($element,$elementPath,$xmlData,$uidTypesHashRef,$uidElementsHashRef) = @_;
	
	if ($element->hasAttribute("type")){
		my $elementType = $element->getAttribute("type");
		
		#if the element's complexType matches a uid keyword
		if (exists $$uidTypesHashRef{$elementType}){
		
			#check if this element has already been expanded, and if so terminate
			if (exists $$uidElementsHashRef{$elementPath}){
				return;
			}
			
			#otherwise, add the element path to the hash
			else{
				#DEBUG
				#print "Storing $elementPath\n";
				$$uidElementsHashRef{$elementPath} = $elementType;
			}
		}
		
		#process child elements
		foreach my $complexType ($xmlData->findnodes('/xs:schema/xs:complexType[@name="'.$elementType.'"]')){
			foreach my $childElement ($complexType->findnodes("./xs:sequence/xs:element")){
				if ($childElement->hasAttribute("name")){
					my $childElementPath = $elementPath."/".$childElement->getAttribute("name");
					checkTypeAndExpandElement($childElement,$childElementPath,$xmlData,$uidTypesHashRef,$uidElementsHashRef);
				}
			}
		}
	}
}

sub searchElements{
	#Search the passed hash of XSD elements for Complex Type keywords, expanding any that
	#are found to continue the search. As the name of an element can be duplicated within 
	#different types, the hierarchy of the path to the name must be stored along with it.
	#XML element names can not contain spaces, so this character can be used to delineate
	#members of the hierarchy.
	 
	#Loop detection can be made by comparing the hierarchy path element names to the 
	#current one under consideration.
	
	my ($xmlData,$uidTypesHashRef,$uidElementsHashRef) = @_;

	#iterate through all elements
	foreach my $element ($xmlData->findnodes("/xs:schema/xs:element")){
		#check element type against list of Type keywords
		if ($element->hasAttribute("name")){
			#DEBUG
			#print "Processing ".$element->getAttribute("name")."\n";
			checkTypeAndExpandElement($element,"/".$element->getAttribute("name"),$xmlData,$uidTypesHashRef,$uidElementsHashRef);
		}
	}
}

sub checkValidCVariableName{

    my ($name,$cReservedWordsRE) = @_;
    if ($name !~ /^[A-Za-z_][A-Za-z_0-9]*$/){
    	#invalid characters in the variable name
    	print "WARNING: Invalid characters dropped in name: $name. ";
    	$name =~ s/[^A-Za-z_0-9]//g; #drop all non-valid characters
		if($name =~ /^[0-9].*$/){$name = "_" . $name;} #prepend with _ if 0-9 appears 1st
		print "Sanitised to: $name\n";
    }
    if ($name =~ /^(?:$cReservedWordsRE)$/) {
        #the variable name matches a reserved word
        print "WARNING: Matched name with reserved word: $name. ";
        $name = "_" . $name; #prepend with _
    	print "Trying sanitised name: $name\n";
        $name = checkValidCVariableName($name,$cReservedWordsRE); #check again
    }
    return $name;
}

sub makeFreeHashKey{
	my ($hashRef, $key) = @_;
	while(exists $$hashRef{$key}){$key = "_".$key;} #prepend with _
	return $key;
}

sub findNextFreeArrayIndex{
	my ($arrayRef,$index) = @_;
	while($$arrayRef[$index]){$index++;}
	return $index;
}

my $uidGeneratorPI = 'uidGenerator';	#keyword to denote uid Processing Instruction
my $nameKey = 'name';					#keyword to denote name element
my $uidKey = "uid";						#keyword to denote uid attribute
										
my $xmlIn = '';
my $xsdIn = '';
my $outDir = '';
my $outPreFileName = '';

GetOptions(	'nameKey=s' => \$nameKey,
			'uidKey=s' => \$uidKey,
			'uidGeneratorPI=s' => \$uidGeneratorPI,
			'xmlIn=s' => \$xmlIn,
			'xsdIn=s' => \$xsdIn,
			'outDir=s' => \$outDir,
			'outPreFileName=s' => \$outPreFileName);

#reserved words for checking validity of enumeration variable names
#via http://www.lemoda.net/c/variable-names/
my @cReservedWords = sort {length $b <=> length $a} qw/auto if break
int case long char register continue return default short do sizeof
double static else struct entry switch extern typedef float union for
unsigned goto while enum void const signed volatile/;
my $cReservedWordsRE = join '|', @cReservedWords;

#check outDir finishes with a slash if it contains one
if($outDir =~ /^.*[\/].*[^\/]$/){$outDir = "$outDir/";}
else{if($outDir =~ /^.*[\\].*[^\\]$/){$outDir = "$outDir\\";}}

my $parserLibXML = XML::LibXML->new();

#parse xsd schema to find keywords, storing array of Type names that contain the uid key
if(-e $xmlIn && -e $xsdIn){
	my $xmlData = $parserLibXML->parse_file($xsdIn);
	
	if($xmlData){
		my %uidTypes; 	#store names of complexTypes with the matching processing 
						#instruction, a count of the number of elements of that type found
						#, and the optional attributes of the processing instruction
		
		#iterate through all complexTypes in the schema with the processing instruction
		foreach my $type ($xmlData->findnodes('/xs:schema/xs:complexType[processing-instruction("'.$uidGeneratorPI.'")]')){
			if($type->hasAttribute("name")){
				foreach my $childNode ($type->getChildNodes){
					if(	$childNode->nodeType eq XML_PI_NODE && 
						$childNode->nodeName eq $uidGeneratorPI){
						
						my $nodeDataString = $childNode->getData();
						$nodeDataString =~ s/"//g; #remove quotation marks
						
						$uidTypes{$type->getAttribute("name")}[0] = -1; #Element count
						$uidTypes{$type->getAttribute("name")}[1] = {split(/[ =]/,$nodeDataString)};
					}
				}
			}
			else{
				print STDERR "ERROR: missing \"name\" attribute for XSD complexType. EXIT\n";
				exit 1;
			}
		}
	
		#DEBUG		
		#print Dumper(%uidTypes);
		
		#on a second pass, identify which element names are of a Type requiring a uid
		#-process xs:complexType:
		#-process xs:element:
		my %uidElements;
		my $uidElementsHashRef = \%uidElements;
		
		#recursively search for elements with keyword types and store hierarchy paths
		searchElements($xmlData,\%uidTypes,$uidElementsHashRef);

		#DEBUG check uidElements for correctness
		#print Dumper($uidElementsHashRef);
		
		#parse xml in file to find Types, counting them and creating enumeration keys
		$xmlData = $parserLibXML->parse_file($xmlIn);
		
		#validate xmlIn with xsdIn
		my $xmlSchema = XML::LibXML::Schema->new('location' => $xsdIn);
		eval {$xmlSchema->validate($xmlData);};
		die $@ if $@;
		
		#output either generated or manually set uids to header file per complexType
		if($xmlData){						
			foreach my $elementPath (keys %uidElements){

				my $uidElementType = $uidElements{$elementPath};				
				my @uidElementInstances = $xmlData->findnodes($elementPath);
				
				if(@uidElementInstances > 0){
					
					my $headerFileName = "$outPreFileName$uidElementType.h";
					my $headerFilePath = "$outDir$headerFileName";
					my @enumerations = '';
					my %enumerationNames;
					
					#store string to prepend all enumeration names, depending on 
					#processing instruction parameters
					my $preName = ''; 
					if(exists $uidTypes{$uidElementType}[1]{"prepName"}){

						if($uidTypes{$uidElementType}[1]{"prepName"} eq "ComplexType"){
							
							$preName = $uidElementType . "_";
							
							if(exists $uidTypes{$uidElementType}[1]{"prepCase"}){
								if($uidTypes{$uidElementType}[1]{"prepCase"} eq "snakeUpper"){
									$preName = uc(decamelize($preName));
									$preName =~ s/ /_/g;
								}
							}
						}
					}
					
					#DEBUG
					#print STDOUT "prependNameString: $preName\n";
					
					#open new file if this is the first element of its type
					if($uidTypes{$uidElementType}[0] < 0){
						$uidTypes{$uidElementType}[0] = 0;
						my $date = localtime();
						open(HFILE,">",$headerFilePath);
						print HFILE	qq~
#ifndef INC_\U$outPreFileName$uidElementType\E_H
#define INC_\U$outPreFileName$uidElementType\E_H

/*
 * $headerFileName
 *
 * $date
 */
 
enum{
~;				
					}
					else{open(HFILE,">>",$headerFileName);}
					
					my $enumerationCount = $uidTypes{$uidElementType}[0];
					
					foreach my $uidElement (@uidElementInstances){
						#add enumeration key at the correct index, filtering name
						my $enumName = '';
						foreach my $nameElement ($uidElement->getChildrenByTagName($nameKey)){
							my $saveUidFlag = 1; #can choose not to store the uid mapping
							
							my $elementName = $nameElement->textContent;
							
							#check if name is valid, and not a C reserved word
							if($elementName){
								$enumName = checkValidCVariableName($elementName,
																	$cReservedWordsRE);
								if($preName){$enumName = $preName.$enumName;}
							}
							else{print STDERR "ERROR: missing \"$nameKey\" element content for ".
								"element of type \"$uidElementType\". EXIT\n";
								exit 1;
							}
							
							my $uidManualFlag = 0;
							my $uidCandidate = '';
							
							#check if the uid has been manually set for the element
							if($uidElement->hasAttribute($uidKey)){
								#check the stored uid is a valid, positive integer
								if($uidElement->getAttribute($uidKey) =~ /^\d+$/){
									$uidCandidate = $uidElement->getAttribute($uidKey);
									$uidManualFlag = 1;
								}
							}
							
							#if no valid manual uid has been set, then use the enumeration
							#count
							if(!$uidManualFlag){$uidCandidate = $enumerationCount;}
							
							#check for collision with selected uid
							if($enumerations[$uidCandidate]){
								if($uidManualFlag){
									#if there is a manually set uid mapping in place, exit
									#if the names do not match
									if($enumerations[$uidCandidate][1]){
										if($enumName !~ $enumerations[$uidCandidate][0]){
											print STDERR "ERROR: \"$uidCandidate\" uid, manually ".
											"set for element named \"$enumName\", has already been".
											" manually set for $enumerations[$uidCandidate][0]. EXIT\n";
											exit 1;
										}
										else{
											print STDERR "WARNING: \"$uidCandidate\" uid, manually ".
											"set for element named \"$enumName\", has already been".
											" manually set for the same name. IGNORING\n";
											$saveUidFlag = 0;
										}
									}
									else{
										#displace the element with the automatically set uid
										my $newUid = findNextFreeArrayIndex(\@enumerations,$uidCandidate);
										$enumerations[$newUid] = $enumerations[$uidCandidate];
										$enumerationCount = ($newUid + 1); #try next index next time
										
										#update the enumerationNames hash for displaced mapping
										$enumerationNames{$enumerations[$newUid][0]} = $enumerations[$newUid][1];
									}
								}
								else{
									#automatically increment enumerationCount, until no 
									#collision is found for those Elements without a 
									#manually set uid
									$uidCandidate = findNextFreeArrayIndex(\@enumerations,$uidCandidate);
									$enumerationCount = ($uidCandidate + 1);
								}
							}
							
							#store the data
							if($saveUidFlag){								
								#check name wanted has not already been used and sanitise
								if(exists $enumerationNames{$enumName}){
									print STDERR "WARNING: \"$enumName\" name has already been ".
												"used for element with uid \"$enumerationNames{$enumName}. ";
									$enumName = makeFreeHashKey(\%enumerationNames,$enumName);
									print STDERR "Changing element name to \"$enumName\"\n";
								}
								
								if(!$uidManualFlag){
									#if auto generated, store uid in attribute to create   
									#linkage between Element and enumeration index
									$uidElement->setAttribute($uidKey,$uidCandidate);
									#DEBUG
									#print STDOUT "DEBUG: $enumName Element, Attribute set: $uidKey=$uidCandidate\n";
								}
								$enumerations[$uidCandidate] = [$enumName,$uidManualFlag];
								$enumerationNames{$enumName} = $uidCandidate;
							}
						}
						$uidTypes{$uidElementType}[0]=$enumerationCount;
					}
					
					#DEBUG check enumerations and enumerationNames for correctness
					#print Dumper(@enumerations);
					#print Dumper(%enumerationNames);

					
					#output enumeration information to the header file
					my $enumerationGapFlag = 0;
					for(my $i = 0;$i<scalar(@enumerations);$i++){
						if($enumerations[$i]){
							print HFILE "$enumerations[$i][0]";
							
							if($enumerationGapFlag){
								print HFILE " = $i"; #reset enumeration count after gap
								$enumerationGapFlag = 0;
							}
							
							#add comma and carriage return if not the last enumeration
							if($i != (scalar(@enumerations)-1)){print HFILE ",\n"}
						}
						else{$enumerationGapFlag = 1;}
					}
					
					close(HFILE);
					
					#overwrite XML document file in case any auto generated uids have been
					#used
					$xmlData->toFile($xmlIn);
				}
			}
			
			#DEBUG
			#print Dumper(%uidTypes);
			
			#go through the uidTypes hash, and for all entries with a non-zero value
			# we must add an extra line to the end of the file to close the "ifdef"  
			#header guard
			while (my ($uidElementType,@uidTypeData) = each (%uidTypes)){
				if($uidTypeData[0] >= 0){
					my $headerFilePath = "$outDir$outPreFileName$uidElementType.h";
					open(HFILE,">>",$headerFilePath);
					print HFILE "\n};\n\n#endif\n";
					close(HFILE);
				}
			}
			
			#DEBUG check uidElements for correctness
			#print Dumper($uidElementsHashRef);
		}
		else{
			print STDERR "xmlIn($xmlIn) is not a valid xml file. EXIT\n";
			exit 1;
		}
	}
	else{
		print STDERR "xsdIn($xsdIn) is not a valid xml file. EXIT\n";
		exit 1;
	}
}
else{
	print STDERR "Options --xsdIn --xmlIn are required. EXIT\n";
	exit 1;
}