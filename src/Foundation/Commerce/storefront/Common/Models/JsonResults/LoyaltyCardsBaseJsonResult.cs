﻿//-----------------------------------------------------------------------
// <copyright file="LoyaltyCardsBaseJsonResult.cs" company="Sitecore Corporation">
//     Copyright (c) Sitecore Corporation 1999-2016
// </copyright>
// <summary>Defines the LoyaltyCardsBaseJsonResult class.</summary>
//-----------------------------------------------------------------------
// Copyright 2016 Sitecore Corporation A/S
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file 
// except in compliance with the License. You may obtain a copy of the License at
//       http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software distributed under the 
// License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, 
// either express or implied. See the License for the specific language governing permissions 
// and limitations under the License.
// -------------------------------------------------------------------------------------------

using System.Collections.Generic;
using Sitecore.Commerce.Entities.LoyaltyPrograms;
using Sitecore.Commerce.Services;
using Sitecore.Diagnostics;

namespace Sitecore.Reference.Storefront.Models.JsonResults
{
    public class LoyaltyCardsBaseJsonResult : BaseJsonResult
    {
        public LoyaltyCardsBaseJsonResult()
        {
        }

        public LoyaltyCardsBaseJsonResult(ServiceProviderResult result)
            : base(result)
        {
        }

        public List<LoyaltyCardItemBaseJsonResult> LoyaltyCards { get; } = new List<LoyaltyCardItemBaseJsonResult>();

        public virtual void Initialize(IEnumerable<LoyaltyCard> loyaltyCards)
        {
            Assert.ArgumentNotNull(loyaltyCards, nameof(loyaltyCards));

            foreach (var card in loyaltyCards)
            {
                var result = new LoyaltyCardItemBaseJsonResult();
                result.Initialize(card);
                LoyaltyCards.Add(result);
            }
        }
    }
}