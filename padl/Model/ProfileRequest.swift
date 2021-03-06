//
//  ProfileRequest.swift
//  padl
//
//  Created by Nikhil Murthy on 6/29/18.
//  Copyright © 2018 Padl. All rights reserved.
//

import Foundation
import FirebaseAuth
import Alamofire
import SwiftyJSON
import Kingfisher

class ProfileRequest {
    
    static let serverURL: String = "https://testing.padl.store";
    static var displayName : String?;
    static var profileURL : URL?;
    static var profilePic : UIImage?;
    static var offers : [String] = [];
    static var offersURL : [String] = [];
    
    static func setupProfile(profileVC : ProfileViewController) {
        
        if Auth.auth().currentUser != nil {
            let user = Auth.auth().currentUser
            if let user = user {
                let uid = user.uid
                
                Alamofire.request(serverURL + "/users/" + uid)
                    .responseJSON { response in
                        
                        if let json_result = response.result.value {
                            let json = JSON(json_result)
                            
                            self.displayName = json["displayName"].stringValue
                            self.profileURL = URL(string: json["propic"].stringValue)
                            
                            let data = try? Data(contentsOf: profileURL!) //make sure your image in this url does exist, otherwise unwrap in a if let check / try-catch
                            self.profilePic = UIImage(data: data!)
                            
                            var offerIdArray = [String]()
                            for (key,_):(String, JSON) in json["offers"] {
                                if key != "sentinel"{
                                    offerIdArray.append(key)
                                }
                            }
                            
                            self.offers = offerIdArray
                        
                            setupOffers(profileVC: profileVC)
                        }
                }
            }
        }
    }
    
    static func setupProfile() {
        
        if Auth.auth().currentUser != nil {
            let user = Auth.auth().currentUser
            if let user = user {
                let uid = user.uid
                
                Alamofire.request(serverURL + "/users/" + uid)
                    .responseJSON { response in
                        
                        if let json_result = response.result.value {
                            let json = JSON(json_result)
                            
                            self.displayName = json["displayName"].stringValue
                            self.profileURL = URL(string: json["propic"].stringValue)
                            
                            let data = try? Data(contentsOf: profileURL!) //make sure your image in this url does exist, otherwise unwrap in a if let check / try-catch
                            self.profilePic = UIImage(data: data!)
                            
                            var offerIdArray = [String]()
                            for (key,_):(String, JSON) in json["offers"] {
                                if key != "sentinel"{
                                    offerIdArray.append(key)
                                }
                            }
                            
                            self.offers = offerIdArray
                            
                            setupOffers()
                        }
                }
            }
        }
    }
    
    static func setupOffers() {
        for offer in self.offers {
            Alamofire.request(serverURL + "/offers/" + offer)
                .responseJSON { response in

                    if let json_result = response.result.value {
                        let json = JSON(json_result)

                        for (key,val):(String, JSON) in json["pictures"] {
                            if key == "0" {
                                self.offersURL.append(val.stringValue)
                            }
                        }
                    }
                    
                    // if offer is last element
                    if self.offers[self.offers.count - 1] == offer {
                        store()
                    }
                }

        }
    }
    
    static func setupOffers(profileVC : ProfileViewController) {
        for offer in self.offers {
            Alamofire.request(serverURL + "/offers/" + offer)
                .responseJSON { response in
                    
                    if let json_result = response.result.value {
                        let json = JSON(json_result)
                        
                        for (key,val):(String, JSON) in json["pictures"] {
                            if key == "0" {
                                self.offersURL.append(val.stringValue)
                            }
                        }
                    }
                    
                    // if offer is last element
                    if self.offers[self.offers.count - 1] == offer {
                        store()
                        profileVC.setProfileInfo()
                    }
            }
            
        }
    }
    
    static func store() {
        let defaults = UserDefaults.standard
        defaults.set(self.displayName, forKey: "displayName")
        defaults.set(self.profileURL, forKey: "profileURL")
        defaults.set(self.offersURL, forKey: "offers")
        ImageCache.default.store(self.profilePic!, forKey: "profilePic")
    
    }
}

