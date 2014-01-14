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

#xmlToHeader will search an input XSD file for Types containing Processor Instructions 
#with a target the same as a specified keyword (default 'uidGenerator'). Elements of this 
#type will be checked for in an input XML file. Those found will have a specified element 
#value paired with an enumeration in a C header file. The value of the specified element 
#must be filtered to ensure that it's unique, and only contain valid characters for an 
#enumeration name. The default element name is "name".

#The default behaviour is to output a header file per Type (i.e. "global").

#TODO: alter the script to allow for the processor instruction to be specified to have 
#scoped or global application for a given element type (i.e. whether the uid pool for a
#single header file is sourced from multiple instances of an element under the same 'Type' 
#hierarchy, or if all elements of a given type, regardless of their parent element 
#structure are pooled. Throw warnings if element naming keys collide, once any hierarchy 
#stripping has been applied.
 
use strict;
use Getopt::Long;
use XML::LibXML;
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

my $uidGeneratorPI = 'uidGenerator';	#keyword to denote uid Processing Instruction
my $nameKey = 'name';					#keyword to denote name element
my $uidKey = "uid";						#keyword to denote uid attribute

my $xmlIn = '';
my $xsdIn = '';
my $outDir = '';

GetOptions(	'nameKey=s' => \$nameKey,
			'uidKey=s' => \$uidKey,
			'uidGeneratorPI=s' => \$uidGeneratorPI,
			'xmlIn=s' => \$xmlIn,
			'xsdIn=s' => \$xsdIn,
			'outDir=s' => \$outDir);

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
		my %uidTypes;
		
		#iterate through all complexTypes in the schema
		foreach my $type ($xmlData->findnodes('/xs:schema/xs:complexType[processing-instruction("'.$uidGeneratorPI.'")]')){
			if($type->hasAttribute("name")){
				$uidTypes{$type->getAttribute("name")} = 0;
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
		#TODO: Start Here: throw warnings on collisions, comparing manually set uids, if 
		#they exist
		searchElements($xmlData,\%uidTypes,$uidElementsHashRef);

		#DEBUG check uidElements for correctness
		#print Dumper($uidElementsHashRef);
		
		#parse xml in file to find Types, counting them and creating enumeration keys
		$xmlData = $parserLibXML->parse_file($xmlIn);
		
		#validate xmlIn with xsdIn
		my $xmlSchema = XML::LibXML::Schema->new('location' => $xsdIn);
		eval {$xmlSchema->validate($xmlData);};
		die $@ if $@;
		
		if($xmlData){			
			#inject uids in XMLData
			
			#TODO: Start Here: code in consideration for whether an element's uid has been manually  
			#set before processing, allowing these to populate the scoped pool, checking for reuse by 
			#indexing the data structure used per enumeration by uid. Output the final data structure 
			#of named uids, accounting for a non-contiguous use of the range of values (i.e. using 
			#'"NAME" = value' to specify where to start counting from again).
			#
			#Populate a data structure to store name and uid pairs, and whether the uid 
			#was manually set. Iterate through all elements, keeping track of the lowest 
			#unused uid. A manually set uid takes priority over previously generated uids,
			# displacing them. Collisions for manually set uids throw warnings.
			#
			#Then walk the data structure, outputting it to a header file.
			
			foreach my $elementPath (keys %uidElements){

				my $uidElementType = $uidElements{$elementPath};				
				my @uidElementInstances = $xmlData->findnodes($elementPath);
				
				if(@uidElementInstances > 0){
					
					my $headerFileName = "$outDir$uidElementType.h";
					
					#open new file if this is the first element of its type
					if($uidTypes{$uidElementType} <= 0){
						my $date = localtime();
						open(HFILE,">",$headerFileName);
						print HFILE	qq~
#ifndef
INC_\U$uidElementType\E_H
#define
INC_\U$uidElementType\E_H

/*
 * $uidElementType.h
 *
 * $date
 */
 
enum{
~;				
					}
					else{open(HFILE,">>",$headerFileName);}
					
					foreach my $uidElement (@uidElementInstances){
						#add enumeration key to the correct header file, filtering name
						my $enumName = $uidElementType; #default to type name
						foreach my $namedElement ($uidElement->getChildrenByTagName($nameKey)){
							my $elementName = $namedElement->textContent;
							if($elementName){
								$enumName = checkValidCVariableName($elementName,
																	$cReservedWordsRE);
							}
							
						}
						
						#TODO: in the future, check for duplicate names of the same type to 
						#ensure no duplicate enumeration names
						
						#write the enumeration line
						if($uidTypes{$uidElementType} <= 0){print HFILE "$enumName";}
						else{print HFILE ",\n$enumName";}
						
						$uidTypes{$uidElementType}++;
					}
					
					close(HFILE);
				}
			}
			
			#go through the uidTypes hash, and for all entries with a non-zero value
			# we must add an extra line to the end of the file to close the "ifdef"  
			#header guard
			while (my ($uidType,$elementCount) = each (%uidTypes)){
				if($elementCount > 0){
					my $headerFileName = "$outDir$uidType.h";
					open(HFILE,">>",$headerFileName);
					print HFILE "\n};\n\n#endif";
					close(HFILE);
				}
			}
			
			#DEBUG check uidElements for correctness
			#print Dumper($uidElementsHashRef);
		}
		else{print STDERR "xmlIn($xmlIn) is not a valid xml file. EXIT\n";}
	}
	else{print STDERR "xsdIn($xsdIn) is not a valid xml file. EXIT\n";}
}
else{print STDERR "Options --xsdIn --xmlIn are required. EXIT\n";}