@import Foundation;
@import ClassDumpDyld;

int main(int argc, char **argv, char **envp) {
    
    ClassDumpDyldManager *manager = [ClassDumpDyldManager sharedManager];
    manager.debug = YES;
    [manager dumpHeadersToPath:@"/Users/JH/Desktop/UXKit"];
    return 0;
    
}
